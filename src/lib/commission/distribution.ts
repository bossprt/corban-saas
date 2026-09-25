// Commission distribution (F4). Exact decimal arithmetic only (money.ts); every line is rounded to cents
// (half away from zero) and the company line is the remainder, so the lines always add up to the amount received.
// MUST stay identical to private.distribute_commission_amount / private.deferred_schedule in the database;
// tests/unit/commission-distribution.test.ts and tests/security/commission-engine-contract.sql pin the same numbers.
import { cmp, div, fromDecimalString, mul, sub, toDecimalString, type Rational } from './money'

export type DistributionMode = 'cascade' | 'group_table'

export type DistributionRule = {
  mode: DistributionMode
  taxRatePct: string        // company tax regime, e.g. '6'
  taxExempt: boolean        // the paying source (bank or promoter) pays commission already free of tax
  profitPct: string         // cascade: company profit, % of the base (received − tax)
  managerPct: string        // cascade: % of the distributable; group_table: % of the base
  supervisorPct: string     // same as managerPct
  originatorPct: string     // cascade: % of the distributable; group_table: fallback % of the base when the seller has no group share
}

export type DistributionInput = {
  received: string          // amount received for one component (or one deferred installment), 2 decimals
  rule: DistributionRule
  hasManager: boolean       // no manager/supervisor on the sale: their part stays with the company
  hasSupervisor: boolean
  hasOriginator: boolean
  groupSharePct?: string | null  // group_table: the seller's commission group share on this table, % of the base
}

export type DistributionLines = { received: string; tax: string; manager: string; supervisor: string; originator: string; company: string }

const HUNDRED = fromDecimalString('100')
const ZERO = fromDecimalString('0')
const cents = (r: Rational) => fromDecimalString(toDecimalString(r, 2))
const pctOf = (base: Rational, pct: string) => cents(div(mul(base, fromDecimalString(pct)), HUNDRED))

export function distribute(input: DistributionInput): DistributionLines {
  const { rule } = input
  const received = fromDecimalString(input.received)
  if (cmp(received, ZERO) < 0) throw new Error('negative_received')
  const tax = rule.taxExempt ? ZERO : pctOf(received, rule.taxRatePct)
  const base = sub(received, tax)

  let manager = ZERO, supervisor = ZERO, originator = ZERO
  if (rule.mode === 'cascade') {
    const profit = pctOf(base, rule.profitPct)
    const distributable = sub(base, profit)
    if (input.hasManager) manager = pctOf(distributable, rule.managerPct)
    if (input.hasSupervisor) supervisor = pctOf(distributable, rule.supervisorPct)
    if (input.hasOriginator) originator = pctOf(distributable, rule.originatorPct)
  } else {
    if (input.hasManager) manager = pctOf(base, rule.managerPct)
    if (input.hasSupervisor) supervisor = pctOf(base, rule.supervisorPct)
    if (input.hasOriginator) originator = pctOf(base, input.groupSharePct ?? rule.originatorPct)
  }

  const company = sub(sub(sub(base, manager), supervisor), originator)
  if (cmp(company, ZERO) < 0) throw new Error('payout_exceeds_received')
  const s = (r: Rational) => toDecimalString(r, 2)
  return { received: s(received), tax: s(tax), manager: s(manager), supervisor: s(supervisor), originator: s(originator), company: s(company) }
}

// Deferred commission paid over the client's installments: each installment rounded to cents, the residual in the
// last one. When rounding up would make the others exceed the total, installments are truncated instead.
export function deferredSchedule(total: string, installments: number): { count: number; standard: string; last: string } {
  if (!Number.isInteger(installments) || installments < 1) throw new Error('invalid_installments')
  const t = fromDecimalString(total)
  const n = fromDecimalString(String(installments))
  let standard = cents(div(t, n))
  const others = mul(standard, fromDecimalString(String(installments - 1)))
  if (cmp(others, t) > 0) {
    const scaled = div(mul(t, HUNDRED), n)
    standard = div(fromDecimalString(String(scaled.n / scaled.d)), HUNDRED) // truncate to cents
  }
  const last = sub(t, mul(standard, fromDecimalString(String(installments - 1))))
  return { count: installments, standard: toDecimalString(standard, 2), last: toDecimalString(last, 2) }
}
