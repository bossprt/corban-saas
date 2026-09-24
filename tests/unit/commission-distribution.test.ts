import test from 'node:test'
import assert from 'node:assert/strict'
import { deferredSchedule, distribute, type DistributionRule } from '../../src/lib/commission/distribution'
import { add, fromDecimalString, toDecimalString } from '../../src/lib/commission/money'

// The owner-approved example (F4): contract R$ 10.000,00, bank pays 6% upfront, tax 6%.
const cascade: DistributionRule = { mode: 'cascade', taxRatePct: '6', taxExempt: false, profitPct: '40', managerPct: '10', supervisorPct: '15', originatorPct: '75' }
const table: DistributionRule = { mode: 'group_table', taxRatePct: '6', taxExempt: false, profitPct: '0', managerPct: '3', supervisorPct: '5', originatorPct: '0' }
const all = { hasManager: true, hasSupervisor: true, hasOriginator: true }
const sum = (l: Record<string, string>) => toDecimalString(['tax', 'manager', 'supervisor', 'originator', 'company'].map(k => fromDecimalString(l[k])).reduce(add), 2)

test('cascade: the approved example to the cent', () => {
  const l = distribute({ received: '600.00', rule: cascade, ...all })
  assert.deepEqual(l, { received: '600.00', tax: '36.00', manager: '33.84', supervisor: '50.76', originator: '253.80', company: '225.60' })
  assert.equal(sum(l), '600.00')
})

test('group table: the approved example to the cent', () => {
  const l = distribute({ received: '600.00', rule: table, ...all, groupSharePct: '50' })
  assert.deepEqual(l, { received: '600.00', tax: '36.00', manager: '16.92', supervisor: '28.20', originator: '282.00', company: '236.88' })
  assert.equal(sum(l), '600.00')
})

test('no manager or supervisor on the sale: their part stays with the company', () => {
  const l = distribute({ received: '600.00', rule: cascade, hasManager: false, hasSupervisor: false, hasOriginator: true })
  assert.equal(l.originator, '253.80')
  assert.equal(l.company, '310.20') // 225.60 profit + 33.84 + 50.76
  assert.equal(sum(l), '600.00')
})

test('exempt paying source: no tax', () => {
  const l = distribute({ received: '600.00', rule: { ...cascade, taxExempt: true }, ...all })
  assert.equal(l.tax, '0.00')
  assert.equal(l.originator, '270.00') // 600 − 40% = 360 distributable × 75%
  assert.equal(sum(l), '600.00')
})

test('lines always add up to the amount received, whatever the rounding', () => {
  for (const received of ['0.01', '0.07', '11.67', '11.27', '999.99', '1234.56', '0.00']) {
    for (const rule of [cascade, table]) {
      const l = distribute({ received, rule, ...all, groupSharePct: '33.3333' })
      assert.equal(sum(l), toDecimalString(fromDecimalString(received), 2), `${rule.mode} ${received}`)
    }
  }
})

test('payout above the base is refused, never paid from nothing', () => {
  assert.throws(() => distribute({ received: '100.00', rule: { ...table, managerPct: '50', supervisorPct: '50' }, ...all, groupSharePct: '50' }), /payout_exceeds_received/)
})

test('deferred schedule: the approved example and the extreme cases', () => {
  assert.deepEqual(deferredSchedule('1400.00', 120), { count: 120, standard: '11.67', last: '11.27' })
  assert.deepEqual(deferredSchedule('1.00', 120), { count: 120, standard: '0.00', last: '1.00' })
  assert.deepEqual(deferredSchedule('1.00', 3), { count: 3, standard: '0.33', last: '0.34' })
  assert.deepEqual(deferredSchedule('2.00', 3), { count: 3, standard: '0.67', last: '0.66' })
  for (const [total, n] of [['1400.00', 120], ['1.00', 120], ['0.50', 84], ['12345.67', 96]] as const) {
    const s = deferredSchedule(total, n)
    const back = add(fromDecimalString(s.standard), { n: BigInt(0), d: BigInt(1) })
    assert.ok(Number(s.last) >= 0, `${total}/${n}`)
    assert.equal(toDecimalString(add({ n: back.n * BigInt(n - 1), d: back.d }, fromDecimalString(s.last)), 2), total)
  }
})

test('the example deferred installment in cascade', () => {
  const l = distribute({ received: '11.67', rule: cascade, ...all })
  // distributable 6.58 × 75% = 4.935 → 4.94 (the first version of the example said 4.93 by mistake)
  assert.deepEqual([l.tax, l.manager, l.supervisor, l.originator, l.company], ['0.70', '0.66', '0.99', '4.94', '4.38'])
  assert.equal(sum(l), '11.67')
})
