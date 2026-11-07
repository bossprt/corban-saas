import test from 'node:test'
import assert from 'node:assert/strict'
import { batchTotals, expectedAmount, isPositiveAmount, markAll, sameAmount, sumAmounts } from '../../src/lib/payout/pay-safety'

test('isPositiveAmount: only a decimal text above zero', () => {
  assert.equal(isPositiveAmount('0.01'), true)
  assert.equal(isPositiveAmount('309.83'), true)
  for (const v of ['0', '0.00', '-1.00', '', null, undefined, 'abc', '1,00']) assert.equal(isPositiveAmount(v), false, String(v))
})

test('expectedAmount: two decimals, positive, else null', () => {
  assert.equal(expectedAmount('42.00'), '42.00')
  assert.equal(expectedAmount(' 150.10 '), '150.10')
  for (const v of ['42', '42.0', '42,00', '0.00', '-1.00', '', null, '1234567890123.00']) assert.equal(expectedAmount(v), null, String(v))
})

test('sameAmount ignores the scale', () => {
  assert.equal(sameAmount('100', '100.00'), true)
  assert.equal(sameAmount(42, '42.00'), true)
  assert.equal(sameAmount('42.00', '-40.00'), false)
  assert.equal(sameAmount(null, '0'), false)
})

test('sumAmounts adds decimal text exactly', () => {
  assert.equal(sumAmounts(['0.10', '0.20']), '0.30')
  assert.equal(sumAmounts(['309.83', '42.00', '150']), '501.83')
  assert.equal(sumAmounts([]), '0.00')
})

test('markAll ticks only people with a PIX key or bank account and lists the others', () => {
  const lines = [{ account: 'a', method: 'pix' }, { account: 'b', method: null }, { account: 'c', method: 'ted' }]
  const r = markAll(lines)
  assert.deepEqual([...r.checked].sort(), ['a', 'c'])
  assert.deepEqual(r.skipped.map(l => l.account), ['b'])
})

test('batchTotals counts only paid payments; undone apart', () => {
  const t = batchTotals([{ status: 'paid', amount: '309.83' }, { status: 'reversed', amount: '150.00' }, { status: 'paid', amount: '42.00' }])
  assert.deepEqual(t, { paidCount: 2, paidTotal: '351.83', undoneCount: 1, undoneTotal: '150.00' })
})
