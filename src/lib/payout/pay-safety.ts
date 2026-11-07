import { add, cmp, fromDecimalString, toDecimalString } from '../commission/money'

// Safe seller payments (audit 06/11/2026). Money is decimal text from the database, never a float.

const ZERO = fromDecimalString('0')
const DECIMAL = /^-?\d+(\.\d+)?$/

// True when the decimal text is a positive amount ('0.00', '-5', '', null and garbage are not).
export function isPositiveAmount(v: string | null | undefined): boolean {
  const s = String(v ?? '').trim()
  return DECIMAL.test(s) && cmp(fromDecimalString(s), ZERO) > 0
}

// Same amount whatever the scale ('100' and '100.00'); false when either is not a decimal.
export function sameAmount(a: string | number | null | undefined, b: string | number | null | undefined): boolean {
  const x = String(a ?? '').trim(), y = String(b ?? '').trim()
  return DECIMAL.test(x) && DECIMAL.test(y) && cmp(fromDecimalString(x), fromDecimalString(y)) === 0
}

// The amount the screen showed, as sent back by the form: digits with exactly two decimals, or null.
export function expectedAmount(v: FormDataEntryValue | string | null | undefined): string | null {
  const s = String(v ?? '').trim()
  return /^\d{1,12}\.\d{2}$/.test(s) && isPositiveAmount(s) ? s : null
}

export const sumAmounts = (values: (string | null | undefined)[]) =>
  toDecimalString(values.reduce((s, v) => add(s, DECIMAL.test(String(v ?? '')) ? fromDecimalString(String(v)) : ZERO), ZERO), 2)

// "Pagar vendedores": only people with a PIX key or a bank account can be ticked; "Marcar todos" skips the others.
export function markAll<T extends { account: string; method: string | null }>(lines: T[]): { checked: Set<string>; skipped: T[] } {
  return { checked: new Set(lines.filter(l => l.method).map(l => l.account)), skipped: lines.filter(l => !l.method) }
}

// One rule for a batch everywhere (list, detail, print, Excel): the total counts only effective payments; the undone
// ones are shown apart.
export function batchTotals(lines: { status: string; amount: string }[]) {
  const paid = lines.filter(l => l.status === 'paid')
  const undone = lines.filter(l => l.status === 'reversed')
  return { paidCount: paid.length, paidTotal: sumAmounts(paid.map(l => l.amount)), undoneCount: undone.length, undoneTotal: sumAmounts(undone.map(l => l.amount)) }
}
