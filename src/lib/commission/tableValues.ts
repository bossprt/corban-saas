// Commission table values (part B, ADR-0036): a % of the operation or a fixed R$, shown and typed in pt-BR.
// Values travel as decimal text; never floating point.

export type ValueKind = 'percentage' | 'fixed_brl'

export const VERSION_STATUS: Record<string, string> = { draft: 'Rascunho', published: 'Vigente', superseded: 'Substituída', expired: 'Expirada' }

// "2.50000000" -> "2,5"; "1250.5" -> "1.250,50" (money keeps 2 decimals).
export function decimalBr(v: string | number | null | undefined, money = false): string {
  if (v === null || v === undefined || v === '') return ''
  const [intRaw, decRaw = ''] = String(v).split('.')
  const neg = intRaw.startsWith('-')
  const int = (neg ? intRaw.slice(1) : intRaw).replace(/^0+(?=\d)/, '')
  const grouped = money ? int.replace(/\B(?=(\d{3})+(?!\d))/g, '.') : int
  let dec = decRaw.replace(/0+$/, '')
  if (money) dec = (dec + '00').slice(0, Math.max(2, dec.length))
  return `${neg ? '-' : ''}${grouped}${dec ? `,${dec}` : ''}`
}

export const valueText = (kind: string, v: string | number | null | undefined) =>
  v === null || v === undefined || v === '' ? '' : kind === 'fixed_brl' ? `R$ ${decimalBr(v, true)}` : `${decimalBr(v)}%`

// What a person types in a value cell: "2,5" (a %), "R$ 25,00" (fixed) or empty (does not apply). Null when invalid.
export function parseValueInput(raw: string): { kind: ValueKind; value: string } | 'empty' | null {
  const t = raw.trim()
  if (!t) return 'empty'
  const fixed = /r\$/i.test(t)
  let s = t.replace(/r\$/i, '').replace(/%$/, '').replace(/\s+/g, '')
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.')
  const m = /^(\d{1,9})(?:\.(\d{1,8}))?$/.exec(s)
  if (!m) return null
  const value = m[2] ? `${m[1].replace(/^0+(?=\d)/, '')}.${m[2]}` : m[1].replace(/^0+(?=\d)/, '')
  if (!fixed && Number(m[1]) > 100) return null
  if (!fixed && Number(m[1]) === 100 && m[2] && /[1-9]/.test(m[2])) return null
  return { kind: fixed ? 'fixed_brl' : 'percentage', value }
}

export const termText = (min: number | null, max: number | null, term?: number | null) =>
  min && max ? (min === max ? `${min}x` : `${min} a ${max}x`) : term ? `${term}x` : '—'

export const rangeText = (min: string | number | null, max: string | number | null) =>
  min === null && max === null ? 'Qualquer valor' : `R$ ${decimalBr(min ?? 0, true)} a ${max === null ? '…' : `R$ ${decimalBr(max, true)}`}`

export const PAGE_SIZES = [10, 25, 50, 100] as const
export const pageSize = (raw: unknown, fallback: number) => {
  const n = Number(raw)
  return (PAGE_SIZES as readonly number[]).includes(n) ? n : fallback
}
