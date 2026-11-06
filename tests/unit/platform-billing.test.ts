import test from 'node:test'
import assert from 'node:assert/strict'
import { minStartMonth, parseSubscriptionAmount } from '../../src/lib/billing'

test('subscription amount accepts comma, dot and thousands separator', () => {
  assert.equal(parseSubscriptionAmount('399,90'), '399.90')
  assert.equal(parseSubscriptionAmount('399.90'), '399.90')
  assert.equal(parseSubscriptionAmount('1.234,56'), '1234.56')
  assert.equal(parseSubscriptionAmount('R$ 399'), '399.00')
  assert.equal(parseSubscriptionAmount(' 399,9 '), '399.90')
})

test('subscription amount refuses zero, empty, three decimals and garbage', () => {
  for (const v of ['', '0', '0,00', '399,901', 'abc', '-10', '123456789,00']) assert.equal(parseSubscriptionAmount(v), null, v)
})

test('three digits after a dot are thousands (Brazilian format), shown back before saving', () => {
  assert.equal(parseSubscriptionAmount('399.901'), '399901.00')
  assert.equal(parseSubscriptionAmount('1.234'), '1234.00')
})

test('first month: a new subscription starts this month; an existing one keeps its own', () => {
  assert.equal(minStartMonth('2026-11-06'), '2026-11')
  assert.equal(minStartMonth('2026-11-06', null), '2026-11')
  assert.equal(minStartMonth('2026-11-06', '2026-09-01'), '2026-09')
  assert.equal(minStartMonth('2026-11-06', '2027-01-01'), '2026-11')
})
