import { add, fromDecimalString, isZero, sub, toDecimalString, type Rational } from '../commission/money'
import { breakdownItemLabel, type Breakdown } from './batches'

// Composition of a payment (owner, 06/11/2026: "quais contratos fazem parte de cada comissão"): Soma dos contratos +
// Outros lançamentos = Total pago. Recomputed here from the items shown, in exact decimals (never floats): when the parts
// do not reach the total, the difference is shown, never hidden.

const dec = (v: string | null | undefined): Rational => fromDecimalString(String(v ?? '0') || '0')
const sum = (values: (string | null | undefined)[]) => values.reduce((s, v) => add(s, dec(v)), dec('0'))

export type BreakdownView = { contractsTotal: string; othersTotal: string; total: string; difference: string; hasDifference: boolean; contractCount: number }

export function breakdownView(b: Pick<Breakdown, 'contracts' | 'others'>, total: string): BreakdownView {
  const contracts = sum((b.contracts ?? []).map(c => c.amount))
  const others = sum((b.others ?? []).map(o => o.amount))
  const diff = sub(sub(dec(total), contracts), others)
  return {
    contractsTotal: toDecimalString(contracts, 2), othersTotal: toDecimalString(others, 2), total: toDecimalString(dec(total), 2),
    difference: toDecimalString(diff, 2), hasDifference: !isZero(diff), contractCount: (b.contracts ?? []).filter(c => c.proposal_id).length,
  }
}

export type FooterItem = { holder: string; label: string; description: string | null; amount: string }
export type BatchFooter = { contractsTotal: string; others: FooterItem[]; othersTotal: string; paidTotal: string; difference: string; hasDifference: boolean }

// Footer of a batch / period (print and Excel): only effective payments (status paid) count.
export function batchFooter(lines: (Pick<Breakdown, 'contracts' | 'others'> & { holder: string; amount: string; status: string })[]): BatchFooter {
  const paid = lines.filter(l => l.status === 'paid')
  const contracts = sum(paid.flatMap(l => (l.contracts ?? []).map(c => c.amount)))
  const items: FooterItem[] = paid.flatMap(l => (l.others ?? []).map(o => ({ holder: l.holder, label: breakdownItemLabel(o), description: o.description, amount: toDecimalString(dec(o.amount), 2) })))
  const others = sum(items.map(i => i.amount))
  const total = sum(paid.map(l => l.amount))
  const diff = sub(sub(total, contracts), others)
  return { contractsTotal: toDecimalString(contracts, 2), others: items, othersTotal: toDecimalString(others, 2), paidTotal: toDecimalString(total, 2), difference: toDecimalString(diff, 2), hasDifference: !isZero(diff) }
}
