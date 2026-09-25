// Seller group payout rule (owner decision 25/09/2026, ADR-0034): for every commission type the company receives, which
// table column the group reads and how many % of it is paid out; plus the supervisor and sales manager basis and %.
// Percentages travel as decimal text end to end: never through floating point.

export type HierarchyBasis = 'spread' | 'production' | 'payout'
export type ReferenceKind = 'own' | 'company' | 'group'

export const BASIS_LABEL: Record<HierarchyBasis, string> = {
  spread: 'Sobre o spread (o que a empresa recebe menos o repasse)',
  production: 'Sobre a produção total',
  payout: 'Sobre a comissão de repasse',
}
export const BASIS_SHORT: Record<HierarchyBasis, string> = { spread: 'spread', production: 'produção total', payout: 'repasse' }
export const isBasis = (v: string): v is HierarchyBasis => v === 'spread' || v === 'production' || v === 'payout'

export type RuleItemInput = { component: string; reference: ReferenceKind; group: string | null; pct: string }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// "100", "65,5", " 2.25 " -> canonical "100", "65.5", "2.25". Null when not a percentage from 0 to 100 with up to 6 decimals.
// The bound is checked on the text: 100 is the only 3-digit integer part allowed, and only with zero decimals.
export function normalizePct(raw: string): string | null {
  const v = raw.trim().replace(',', '.')
  const m = /^(\d{1,3})(?:\.(\d{1,6}))?$/.exec(v)
  if (!m) return null
  const int = m[1].replace(/^0+(?=\d)/, '')
  const dec = (m[2] ?? '').replace(/0+$/, '')
  if (int.length === 3 && (int !== '100' || dec !== '')) return null
  return dec ? `${int}.${dec}` : int
}

// Form value of the column choice: "own", "company" or "group:<uuid>".
export function parseReference(raw: string): { reference: ReferenceKind; group: string | null } | null {
  if (raw === 'own' || raw === 'company') return { reference: raw, group: null }
  if (raw.startsWith('group:') && UUID.test(raw.slice(6))) return { reference: 'group', group: raw.slice(6) }
  return null
}
export const referenceValue = (kind: ReferenceKind, group: string | null) => (kind === 'group' ? `group:${group}` : kind)

// "100.000000" (numeric from the database) -> "100,00"; keeps up to 6 decimals, at least 2.
export function pctText(v: string | number | null | undefined): string {
  if (v === null || v === undefined || v === '') return ''
  const [int, dec = ''] = String(v).split('.')
  const trimmed = dec.replace(/0+$/, '')
  return `${int},${trimmed.length >= 2 ? trimmed : (trimmed + '00').slice(0, 2)}`
}
