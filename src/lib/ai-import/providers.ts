import { normalizeHeader } from '../commercial'
import { CANONICAL_FIELDS, type CanonicalField, type FieldProposal, type ImportMapper, type MappingProposal, type MappingRequest } from './types'

// ---------------------------------------------------------------- deterministic fake (tests, local development, and the "no AI" fallback suggestion)
const HINTS: Record<CanonicalField, readonly string[]> = {
  bank: ['banco', 'instituicao'], agreement: ['convenio', 'orgao'], product_table: ['tabela', 'produto'], contract_type: ['tipo_de_contrato', 'tipo_contrato', 'contrato', 'operacao'],
  term: ['prazo', 'parcelas', 'meses'], coefficient: ['coeficiente', 'coef'], rate: ['taxa', 'taxa_mensal', 'juros'], received_commission: ['comissao_recebida', 'comissao', 'comissao_do_banco'],
  valid_from: ['vigencia', 'inicio', 'vigencia_inicio'], valid_until: ['fim', 'vigencia_fim', 'validade'], production_origin: ['origem', 'origem_da_producao'],
}
export function heuristicMapper(id = 'heuristic'): ImportMapper {
  return {
    id, model: 'header-hints-v1',
    async mapColumns(req: MappingRequest): Promise<MappingProposal> {
      const norm = req.headers.map(h => [h, normalizeHeader(h)] as const)
      const fields: FieldProposal[] = []
      for (const field of CANONICAL_FIELDS) {
        const hit = norm.find(([, n]) => HINTS[field].includes(n))
        if (hit) fields.push({ field, column: hit[0], confidence: 0.9, evidence: `O cabeçalho "${hit[0]}" corresponde a ${field}.` })
      }
      return { provider: id, model: 'header-hints-v1', fields, overallConfidence: fields.length ? 0.9 : 0, usage: { inputUnits: 0, outputUnits: 0 } }
    },
  }
}
// A mapper that answers exactly what the test says (including hostile answers).
export function scriptedMapper(answer: Omit<MappingProposal, 'provider' | 'model'> | (() => never), id = 'scripted'): ImportMapper {
  return {
    id, model: 'scripted',
    async mapColumns(): Promise<MappingProposal> {
      if (typeof answer === 'function') return answer()
      return { provider: id, model: 'scripted', ...answer }
    },
  }
}

// ---------------------------------------------------------------- Gemini adapter (preferred initial provider; NO lock-in: it is just one ImportMapper)
// The key is INJECTED by the caller (a server module reading its own environment). This file never reads the environment, never stores a key and never runs on import.
export type GeminiOptions = { apiKey: string; model: string; fetchImpl?: typeof fetch; timeoutMs?: number; maxSampleRows?: number }
const MAX_CELL = 60

export function buildGeminiPrompt(req: MappingRequest, maxRows: number): string {
  const rows = req.sample.slice(0, maxRows).map(r => r.slice(0, req.headers.length).map(c => String(c).slice(0, MAX_CELL)))
  return [
    'You map spreadsheet columns to a fixed list of canonical fields for a Brazilian payroll-loan commercial table.',
    `Canonical fields: ${CANONICAL_FIELDS.join(', ')}.`,
    'Rules: answer ONLY JSON {"fields":[{"field":string,"column":string|null,"confidence":number 0..1,"evidence":string}],"overallConfidence":number}.',
    'Use a column name EXACTLY as it appears in headers, or null when no column fits. Never invent a column. Never output values, only column names. One column per field.',
    `headers: ${JSON.stringify(req.headers)}`,
    `sample rows: ${JSON.stringify(rows)}`,
  ].join('\n')
}

// Strict parse of the model answer: anything that is not exactly the expected shape is an ERROR (the caller falls back to manual mapping).
export function parseGeminiAnswer(text: string): { fields: FieldProposal[]; overallConfidence: number } {
  let raw: unknown
  try { raw = JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '')) } catch { throw new Error('mapper_bad_json') }
  if (typeof raw !== 'object' || raw === null || !Array.isArray((raw as { fields?: unknown }).fields)) throw new Error('mapper_bad_shape')
  const fields: FieldProposal[] = []
  for (const f of (raw as { fields: unknown[] }).fields) {
    if (typeof f !== 'object' || f === null) throw new Error('mapper_bad_shape')
    const o = f as Record<string, unknown>
    if (typeof o.field !== 'string' || !(CANONICAL_FIELDS as readonly string[]).includes(o.field)) continue // an unknown field is ignored, never trusted
    if (o.column !== null && typeof o.column !== 'string') throw new Error('mapper_bad_shape')
    if (typeof o.confidence !== 'number' || !Number.isFinite(o.confidence)) throw new Error('mapper_bad_shape')
    fields.push({ field: o.field as CanonicalField, column: (o.column as string | null), confidence: o.confidence, evidence: typeof o.evidence === 'string' ? o.evidence.slice(0, 300) : '' })
  }
  const overall = (raw as { overallConfidence?: unknown }).overallConfidence
  return { fields, overallConfidence: typeof overall === 'number' && Number.isFinite(overall) ? overall : 0 }
}

export function geminiMapper(opts: GeminiOptions): ImportMapper {
  if (!opts.apiKey || !opts.model) throw new Error('gemini_not_configured')
  const doFetch = opts.fetchImpl ?? fetch
  return {
    id: 'gemini', model: opts.model,
    async mapColumns(req: MappingRequest): Promise<MappingProposal> {
      const ctl = new AbortController()
      const timer = setTimeout(() => ctl.abort(), opts.timeoutMs ?? 20_000)
      try {
        const res = await doFetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(opts.model)}:generateContent`, {
          method: 'POST', signal: ctl.signal,
          headers: { 'content-type': 'application/json', 'x-goog-api-key': opts.apiKey },
          body: JSON.stringify({ contents: [{ role: 'user', parts: [{ text: buildGeminiPrompt(req, opts.maxSampleRows ?? 15) }] }], generationConfig: { temperature: 0, responseMimeType: 'application/json' } }),
        })
        if (!res.ok) throw new Error(`mapper_http_${res.status}`) // the response body is never surfaced (it could echo the request)
        const body = (await res.json()) as { candidates?: { content?: { parts?: { text?: string }[] } }[]; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } }
        const text = body.candidates?.[0]?.content?.parts?.[0]?.text
        if (typeof text !== 'string') throw new Error('mapper_empty_answer')
        const parsed = parseGeminiAnswer(text)
        return { provider: 'gemini', model: opts.model, ...parsed, usage: { inputUnits: Math.max(0, Math.floor(body.usageMetadata?.promptTokenCount ?? 0)), outputUnits: Math.max(0, Math.floor(body.usageMetadata?.candidatesTokenCount ?? 0)) } }
      } catch (e) {
        if (e instanceof Error && /^mapper_/.test(e.message)) throw e
        throw new Error('mapper_unavailable') // network, abort, anything else: one opaque code, never the raw error (it may contain the URL/key)
      } finally { clearTimeout(timer) }
    },
  }
}
