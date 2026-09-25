// Commercial Model V3 helpers (pure, no I/O). The database is the authority (save_commercial_condition validates everything again);
// this mirrors it so forms and imports fail early with a clear message.
// Money and percentages NEVER become a JavaScript float: they travel as canonical decimal STRINGS (PostgREST casts them to numeric) and are only
// compared as scaled BigInt.

export type Basis = 'percent_of_production' | 'percent_of_received_commission'
export type GroupRef = { id: string; name: string; basis: Basis }
export type ContractTypeRef = { id: string; name: string; tech_key: string }
export type ShareInput = { group_id: string; pct: string }

const FACTOR = BigInt(1000000) // 6 decimal places, same as numeric(9,6)

// "1,85" | "1.85" | "1,85%" -> "1.85". Rejects thousands separators, exponents, signs and anything with more digits than the column can store.
export function parseDecimal(raw: unknown, opts: { maxInt: number; scale: number }): string | null {
  let t = String(raw ?? '').trim().replace(/%$/, '').trim()
  if (t === '') return null
  t = t.replace(',', '.')
  const m = /^(\d+)(?:\.(\d+))?$/.exec(t)
  if (!m) return null
  const int = m[1].replace(/^0+(?=\d)/, ''), frac = m[2] ?? ''
  if (int.length > opts.maxInt || frac.length > opts.scale) return null
  return frac ? `${int}.${frac}` : int
}
export const parsePercent = (raw: unknown) => parseDecimal(raw, { maxInt: 3, scale: 6 })
export const parseCoefficient = (raw: unknown) => parseDecimal(raw, { maxInt: 6, scale: 8 })
export const parseRate = (raw: unknown) => parseDecimal(raw, { maxInt: 3, scale: 6 })
export const parseTerm = (raw: unknown): number | null => {
  const t = String(raw ?? '').trim()
  if (!/^\d{1,3}$/.test(t)) return null
  const n = Number(t)
  return n >= 1 && n <= 600 ? n : null
}

// Percentages compared exactly (6 decimal places, same as numeric(9,6)).
export function scaled(dec: string): bigint {
  const [i, f = ''] = dec.split('.')
  return BigInt(i) * FACTOR + BigInt((f + '000000').slice(0, 6))
}
const HUNDRED = BigInt(100) * FACTOR
export function fromScaled(v: bigint): string {
  const i = v / FACTOR, f = String(v % FACTOR).padStart(6, '0').replace(/0+$/, '')
  return f ? `${i}.${f}` : String(i)
}

export type ShareError = 'invalid_shares' | 'duplicate_group_share' | 'commission_group_not_found' | 'production_shares_exceed_received_commission' | 'policy_group_inactive'
export type ShareSource = 'manual' | 'policy' | 'override'
export type PolicyRef = { baseKind: 'gross' | 'net'; discountPct: string; items: readonly ShareInput[] }
export type ResolvedShare = { group_id: string; pct: string; source: ShareSource; effective: string }

// Base for the received-basis groups: the gross received commission, or the net base after the policy's tax/discount (net = received x (1 - discount/100), half-up at 6 places).
export function netBase(received: string, policy?: Pick<PolicyRef, 'baseKind' | 'discountPct'>): bigint {
  const r = scaled(received)
  if (!policy || policy.baseKind !== 'net') return r
  return (r * (HUNDRED - scaled(policy.discountPct)) + HUNDRED / BigInt(2)) / HUNDRED
}
// What a received-basis group really gets as a share of the production: base x pct / 100, half-up at 6 places (identical to round(numeric, 6) in the database).
export const effectiveOf = (base: bigint, pct: string): bigint => (base * scaled(pct) + HUNDRED / BigInt(2)) / HUNDRED

// Mirror of save_commercial_condition. Groups are ALTERNATIVE sellers of the same operation (Corretor OR Parceiro OR Balcao), so the cap is PER GROUP:
// a production-basis percentage cannot exceed the commission the company received; a received-basis percentage is 0..100 of the base. Nothing is summed across groups.
export function resolveShares(groups: readonly (GroupRef & { active?: boolean })[], explicit: readonly ShareInput[], received: string, policy?: PolicyRef): { rows: ResolvedShare[]; error: ShareError | null } {
  const byId = new Map(groups.map(g => [g.id, g]))
  const seen = new Set<string>()
  const rows: { group_id: string; pct: string; source: ShareSource }[] = []
  const inPolicy = new Set((policy?.items ?? []).map(i => i.group_id))
  for (const s of explicit) {
    const pct = parsePercent(s.pct)
    if (pct === null || scaled(pct) > HUNDRED) return { rows: [], error: 'invalid_shares' }
    if (seen.has(s.group_id)) return { rows: [], error: 'duplicate_group_share' }
    seen.add(s.group_id)
    rows.push({ group_id: s.group_id, pct, source: policy && inPolicy.has(s.group_id) ? 'override' : 'manual' })
  }
  for (const i of policy?.items ?? []) if (!seen.has(i.group_id)) { seen.add(i.group_id); rows.push({ group_id: i.group_id, pct: i.pct, source: 'policy' }) }
  const base = netBase(received, policy)
  const out: ResolvedShare[] = []
  for (const r of rows) {
    const g = byId.get(r.group_id)
    if (!g || g.active === false) return { rows: [], error: r.source === 'policy' ? 'policy_group_inactive' : 'commission_group_not_found' }
    const eff = g.basis === 'percent_of_production' ? scaled(r.pct) : effectiveOf(base, r.pct)
    if (g.basis === 'percent_of_production' && scaled(r.pct) > scaled(received)) return { rows: [], error: 'production_shares_exceed_received_commission' }
    out.push({ group_id: r.group_id, pct: r.pct, source: r.source, effective: fromScaled(eff) })
  }
  return { rows: out, error: null }
}
export const validateShares = (groups: readonly GroupRef[], shares: readonly ShareInput[], received: string, policy?: PolicyRef): ShareError | null => resolveShares(groups, shares, received, policy).error

// ---------------------------------------------------------------- file import (CSV / XLSX rows) with ONE COLUMN PER COMMISSION GROUP
export const normalizeHeader = (s: unknown) => String(s ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')

// Minimal RFC-4180 reader: BOM, CRLF, quoted fields with "" escapes, delimiter chosen from the header (; , or tab).
// `delimiter` overrides the choice (bank reports start with a title line that has no delimiter at all).
export function parseDelimited(text: string, delimiter?: ';' | ',' | '\t'): string[][] {
  const src = text.replace(/^\uFEFF/, '')
  const firstLine = src.split(/\r?\n/, 1)[0] ?? ''
  const count = (c: string) => firstLine.split(c).length - 1
  const delim = delimiter ?? (count(';') >= count(',') && count(';') >= count('\t') && count(';') > 0 ? ';' : count('\t') > count(',') ? '\t' : ',')
  const rows: string[][] = []
  let row: string[] = [], cell = '', quoted = false
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (quoted) {
      if (c === '"') { if (src[i + 1] === '"') { cell += '"'; i++ } else quoted = false } else cell += c
    } else if (c === '"') quoted = true
    else if (c === delim) { row.push(cell); cell = '' }
    else if (c === '\n' || c === '\r') { if (c === '\r' && src[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = '' }
    else cell += c
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row) }
  return rows.filter(r => r.some(x => x.trim() !== ''))
}

export type ParsedCondition = { line: number; contractTypeId: string; term: number; coefficient: string | null; rate: string | null; received: string; shares: ShareInput[]; resolved: ResolvedShare[] }
export type ImportIssue = { line: number; code: string; detail?: string }
export const IMPORT_MAX_ROWS = 500

const ALIASES = {
  contract: ['tipo_de_contrato', 'tipo_contrato', 'contrato'],
  term: ['prazo', 'prazo_meses', 'prazo_em_meses'],
  coefficient: ['coeficiente'],
  rate: ['taxa', 'taxa_mensal'],
  received: ['comissao_recebida', 'comissao', 'comissao_do_banco'],
} as const

export function mapConditionRows(rows: readonly (readonly unknown[])[], ctx: { groups: readonly GroupRef[]; contractTypes: readonly ContractTypeRef[]; policy?: PolicyRef }): { conditions: ParsedCondition[]; issues: ImportIssue[] } {
  const issues: ImportIssue[] = []
  const fail = (line: number, code: string, detail?: string) => { issues.push({ line, code, detail }) }
  if (rows.length < 2) { fail(1, 'file_without_rows'); return { conditions: [], issues } }
  if (rows.length - 1 > IMPORT_MAX_ROWS) { fail(1, 'too_many_rows'); return { conditions: [], issues } }

  const groupKey = new Map<string, GroupRef>()
  for (const g of ctx.groups) {
    const k = normalizeHeader(g.name)
    if (groupKey.has(k)) { fail(1, 'ambiguous_group_names', g.name); return { conditions: [], issues } }
    groupKey.set(k, g)
  }
  const head = rows[0].map(normalizeHeader)
  const col: Partial<Record<keyof typeof ALIASES, number>> = {}
  const groupCols = new Map<number, GroupRef>()
  const seenCols = new Set<string>()
  head.forEach((h, i) => {
    if (!h) return
    if (seenCols.has(h)) { fail(1, 'duplicate_column', String(rows[0][i])); return }
    seenCols.add(h)
    const field = (Object.keys(ALIASES) as (keyof typeof ALIASES)[]).find(f => (ALIASES[f] as readonly string[]).includes(h))
    if (field) { col[field] = i; return }
    const g = groupKey.get(h) ?? groupKey.get(h.replace(/^grupo_/, ''))
    // an unknown column is refused, never silently ignored: a typo in a group name would otherwise drop that group's commission
    if (g) groupCols.set(i, g); else fail(1, 'unknown_column', String(rows[0][i]))
  })
  for (const f of ['contract', 'term', 'received'] as const) if (col[f] === undefined) fail(1, `missing_column_${f}`)
  if (col.coefficient === undefined && col.rate === undefined) fail(1, 'missing_column_coefficient_or_rate')
  if (issues.length) return { conditions: [], issues }

  const typeKey = new Map<string, ContractTypeRef>()
  for (const t of ctx.contractTypes) { typeKey.set(normalizeHeader(t.name), t); typeKey.set(normalizeHeader(t.tech_key), t) }
  const conditions: ParsedCondition[] = []
  const seen = new Set<string>()
  rows.slice(1).forEach((r, idx) => {
    const line = idx + 2
    const cell = (i: number | undefined) => (i === undefined ? '' : String(r[i] ?? '').trim())
    const type = typeKey.get(normalizeHeader(cell(col.contract)))
    if (!type) return fail(line, 'unknown_contract_type', cell(col.contract))
    const term = parseTerm(cell(col.term))
    if (term === null) return fail(line, 'invalid_term', cell(col.term))
    const coefficient = cell(col.coefficient) === '' ? null : parseCoefficient(cell(col.coefficient))
    const rate = cell(col.rate) === '' ? null : parseRate(cell(col.rate))
    if ((cell(col.coefficient) !== '' && coefficient === null) || (cell(col.rate) !== '' && rate === null)) return fail(line, 'invalid_number')
    if (coefficient === null && rate === null) return fail(line, 'coefficient_or_rate_required')
    const received = parsePercent(cell(col.received))
    if (received === null || scaled(received) > HUNDRED) return fail(line, 'invalid_received_commission', cell(col.received))
    const shares: ShareInput[] = []
    for (const [i, g] of groupCols) {
      const raw = cell(i)
      if (raw === '') continue // blank = this group is not part of this condition (never read as zero)
      const pct = parsePercent(raw)
      if (pct === null) return fail(line, 'invalid_shares', g.name)
      shares.push({ group_id: g.id, pct })
    }
    const res = resolveShares(ctx.groups, shares, received, ctx.policy)
    if (res.error) return fail(line, res.error)
    const key = `${type.id}|${term}`
    if (seen.has(key)) return fail(line, 'duplicate_row')
    seen.add(key)
    conditions.push({ line, contractTypeId: type.id, term, coefficient, rate, received, shares, resolved: res.rows })
  })
  return { conditions: issues.length ? [] : conditions, issues }
}

// Guided onboarding shown at the top of /app/comercial: what is done, and the ONE next thing to do. Pure and computed from real counts only.
export type OnboardingInput = { banks: number; agreements: number; groups: number; tables: number; draftConditions: number; publishedVersions: number }
export type OnboardingStep = { key: string; label: string; done: boolean; hint: string; anchor: string }
export function onboardingSteps(i: OnboardingInput): { steps: OnboardingStep[]; next: OnboardingStep | null } {
  const steps: OnboardingStep[] = [
    { key: 'bank', label: 'Cadastrar o banco', done: i.banks > 0, hint: 'Digite só o nome. O sistema cuida dos códigos.', anchor: 'passo-bancos' },
    { key: 'agreement', label: 'Habilitar o convênio', done: i.agreements > 0, hint: 'Escolha um governo ou prefeitura da lista, ou cadastre o seu.', anchor: 'passo-convenios' },
    { key: 'group', label: 'Criar os grupos de vendedores', done: i.groups > 0, hint: 'Ex.: Corretor, Parceiro, Balcão. Diga sobre o que o percentual incide.', anchor: 'passo-grupos' },
    { key: 'table', label: 'Criar a tabela', done: i.tables > 0, hint: 'Banco + convênio + origem da produção (Própria ou Terceiro).', anchor: 'passo-tabelas' },
    { key: 'condition', label: 'Cadastrar as condições', done: i.draftConditions > 0 || i.publishedVersions > 0, hint: 'Tipo de Contrato, prazo, coeficiente/taxa, comissão recebida e os grupos, numa linha só.', anchor: 'passo-tabelas' },
    { key: 'publish', label: 'Publicar a versão', done: i.publishedVersions > 0, hint: 'Só versões publicadas entram nas simulações.', anchor: 'passo-tabelas' },
  ]
  return { steps, next: steps.find(s => !s.done) ?? null }
}

// The bulk RPC refuses the whole call with message "bulk_import_rejected" and a DETAIL that is a JSON list of {line, code}. Anything else is not a refusal list.
export function parseBulkRefusal(err: { message?: string; details?: string | null }): { line: number; code: string }[] | null {
  if (!/bulk_import_rejected/.test(String(err.message ?? ''))) return null
  try {
    const list = JSON.parse(String(err.details ?? '')) as unknown
    if (!Array.isArray(list) || !list.length) return null
    const out = list.filter((x): x is { line: number; code: string } => typeof x === 'object' && x !== null && Number.isInteger((x as { line?: unknown }).line) && typeof (x as { code?: unknown }).code === 'string')
    return out.length ? out : null
  } catch { return null }
}

// Whole-file import is all-or-nothing at the validation step: one bad line refuses the file (the operator fixes it and sends again).
export const IMPORT_ISSUE_TEXT: Record<string, string> = {
  file_without_rows: 'O arquivo não tem linhas de dados.',
  too_many_rows: `O arquivo passa de ${IMPORT_MAX_ROWS} linhas. Divida em partes.`,
  ambiguous_group_names: 'Dois grupos de vendedores têm nomes parecidos demais. Renomeie um deles.',
  duplicate_column: 'Coluna repetida.',
  unknown_column: 'Coluna desconhecida (não é um campo nem um grupo de vendedores ativo).',
  missing_column_contract: 'Falta a coluna Tipo de Contrato.',
  missing_column_term: 'Falta a coluna Prazo.',
  missing_column_received: 'Falta a coluna Comissão recebida.',
  missing_column_coefficient_or_rate: 'Falta a coluna Coeficiente ou Taxa.',
  unknown_contract_type: 'Tipo de Contrato desconhecido.',
  invalid_term: 'Prazo inválido (1 a 600).',
  invalid_number: 'Número inválido no coeficiente ou na taxa.',
  coefficient_or_rate_required: 'Informe coeficiente ou taxa.',
  invalid_received_commission: 'Comissão recebida inválida (0 a 100).',
  invalid_shares: 'Percentual de grupo inválido.',
  duplicate_group_share: 'Grupo repetido.',
  commission_group_not_found: 'Grupo de vendedores não encontrado ou inativo.',
  production_shares_exceed_received_commission: 'Um grupo recebe mais do que a comissão recebida pela empresa.',
  policy_group_inactive: 'Um grupo da política de repasse está inativo.',
  duplicate_row: 'Mesmo Tipo de Contrato e prazo repetidos no arquivo.',
  policy_not_found: 'Política de repasse não encontrada ou inativa.',
  contract_type_not_found: 'Tipo de Contrato não encontrado.',
  invalid_row: 'Linha malformada.',
  invalid_rows: 'O arquivo não tem linhas válidas.',
  version_not_draft: 'A versão já foi publicada.',
  unexpected: 'Linha recusada pelo banco de dados.',
}
