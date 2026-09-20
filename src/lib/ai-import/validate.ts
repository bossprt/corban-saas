import { normalizeHeader, parseDecimal, parseTerm } from '../commercial'
import { CANONICAL_FIELDS, FINANCIAL_FIELDS, type CanonicalField, type MappingProposal, type MappingRequest, type ReviewItem, type ValidatedMapping } from './types'
import { createHash } from 'node:crypto'

// Layout fingerprint: same headers in the same order = same layout. Case, accents and punctuation do not change it; a new/renamed/moved column does.
export function layoutFingerprint(headers: readonly string[]): string {
  return createHash('sha256').update(JSON.stringify(headers.map(normalizeHeader))).digest('hex')
}
export const fileFingerprint = (bytes: Uint8Array): string => createHash('sha256').update(bytes).digest('hex')

export const MIN_CONFIDENCE = { financial: 0.85, other: 0.6 } as const
export const REQUIRED_FIELDS: readonly CanonicalField[] = ['contract_type', 'term', 'received_commission']
const clamp01 = (n: unknown) => (typeof n === 'number' && Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0)

// Deterministic check that the sample really looks like the field the model claims (a guess is never enough for money).
function sampleLooksLike(field: CanonicalField, values: readonly string[]): boolean | null {
  const filled = values.map(v => v.trim()).filter(Boolean)
  if (!filled.length) return null
  const ok = (f: (v: string) => boolean) => filled.filter(f).length / filled.length >= 0.8
  switch (field) {
    case 'term': return ok(v => parseTerm(v) !== null)
    case 'coefficient': return ok(v => parseDecimal(v, { maxInt: 6, scale: 8 }) !== null)
    case 'rate':
    case 'received_commission': return ok(v => parseDecimal(v, { maxInt: 3, scale: 6 }) !== null)
    default: return null // names/dates: no numeric evidence to require
  }
}

// Turns a model answer into something a human can review. Everything the model says is checked against the real headers and sample; it can only LOSE trust here.
export function validateProposal(req: MappingRequest, proposal: MappingProposal): ValidatedMapping {
  const byNorm = new Map(req.headers.map(h => [normalizeHeader(h), h]))
  const usedColumns = new Set<string>()
  const items: ReviewItem[] = []
  const mapping: Partial<Record<CanonicalField, string>> = {}
  const seenFields = new Set<CanonicalField>()

  for (const f of proposal.fields) {
    if (!(CANONICAL_FIELDS as readonly string[]).includes(f.field) || seenFields.has(f.field)) continue // outside the closed list or repeated: dropped, not guessed
    seenFields.add(f.field)
    const reasons: string[] = []
    const conf = clamp01(f.confidence)
    const real = f.column ? byNorm.get(normalizeHeader(f.column)) : undefined
    if (f.column && !real) reasons.push('A coluna indicada não existe no arquivo.')
    if (real && usedColumns.has(real)) reasons.push('A mesma coluna foi indicada para dois campos.')
    const financial = FINANCIAL_FIELDS.includes(f.field)
    if (real && !reasons.length) {
      if (conf < (financial ? MIN_CONFIDENCE.financial : MIN_CONFIDENCE.other)) reasons.push('Confiança baixa.')
      const idx = req.headers.indexOf(real)
      const values = req.sample.map(r => r[idx] ?? '')
      const evidence = sampleLooksLike(f.field, values)
      if (evidence === false) reasons.push('Os valores de exemplo não parecem ser deste campo.')
      if (financial && !values.some(v => v.trim())) reasons.push('Sem valores de exemplo para conferir.')
    }
    const status: ReviewItem['status'] = !real ? 'missing' : reasons.length ? 'review' : 'ok'
    if (real && !usedColumns.has(real)) { usedColumns.add(real); if (status === 'ok' || status === 'review') mapping[f.field] = real }
    items.push({ field: f.field, column: real ?? null, confidence: conf, evidence: String(f.evidence ?? '').slice(0, 300), status, reasons })
  }
  for (const field of CANONICAL_FIELDS) if (!seenFields.has(field)) items.push({ field, column: null, confidence: 0, evidence: '', status: 'missing', reasons: ['O modelo não encontrou este campo.'] })

  const unknownColumns = req.headers.filter(h => !usedColumns.has(h)) // preserved for the human, never dropped silently
  const requiredOk = REQUIRED_FIELDS.every(r => items.find(i => i.field === r)?.status === 'ok')
  return { items, mapping, unknownColumns, overallConfidence: clamp01(proposal.overallConfidence), needsReview: !requiredOk || items.some(i => i.status === 'review') }
}

// Reuse of a saved (human confirmed) mapping. Only an IDENTICAL layout is reused as is; a changed layout always goes back to review.
export type SavedMapping = { fingerprint: string; mapping: Partial<Record<CanonicalField, string>>; unknownColumns: readonly string[] }
export type ReuseDecision =
  | { kind: 'reuse'; mapping: Partial<Record<CanonicalField, string>> }
  | { kind: 'review'; reason: 'layout_changed' | 'column_missing' | 'new_columns' | 'no_memory' }
export function reuseDecision(saved: SavedMapping | null, req: Pick<MappingRequest, 'fingerprint' | 'headers'>): ReuseDecision {
  if (!saved) return { kind: 'review', reason: 'no_memory' }
  const have = new Set(req.headers.map(normalizeHeader))
  if (Object.values(saved.mapping).some(c => !c || !have.has(normalizeHeader(c)))) return { kind: 'review', reason: 'column_missing' }
  if (saved.fingerprint === req.fingerprint) return { kind: 'reuse', mapping: saved.mapping }
  const known = new Set([...Object.values(saved.mapping), ...saved.unknownColumns].map(c => normalizeHeader(String(c))))
  return { kind: 'review', reason: req.headers.some(h => !known.has(normalizeHeader(h))) ? 'new_columns' : 'layout_changed' }
}
