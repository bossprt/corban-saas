import { test } from 'node:test'
import { feedbackUrl } from '../../src/lib/feedback'
import { fetchAll } from '../../src/lib/fetchAll'
import assert from 'node:assert/strict'
import { decimalBr, groupPayout, pageSize, parseValueInput, percentOf, rangeText, termText, valueText } from '../../src/lib/commission/tableValues'

test('table values: shown in pt-BR, % trimmed, money with two decimals', () => {
  assert.equal(decimalBr('2.50000000'), '2,5')
  assert.equal(decimalBr('3'), '3')
  assert.equal(decimalBr('1250.5', true), '1.250,50')
  assert.equal(valueText('percentage', '0.8'), '0,8%')
  assert.equal(valueText('fixed_brl', '25'), 'R$ 25,00')
  assert.equal(valueText('percentage', null), '')
})

test('table values: typed as "2,5", "R$ 1.250,50" or empty; nothing else', () => {
  assert.deepEqual(parseValueInput('2,5'), { kind: 'percentage', value: '2.5' })
  assert.deepEqual(parseValueInput('2,5%'), { kind: 'percentage', value: '2.5' })
  assert.deepEqual(parseValueInput('R$ 1.250,50'), { kind: 'fixed_brl', value: '1250.50' })
  assert.deepEqual(parseValueInput('100'), { kind: 'percentage', value: '100' })
  assert.equal(parseValueInput('  '), 'empty')
  for (const bad of ['101', '100,5', 'abc', '1e2', '2,5,1', '-1']) assert.equal(parseValueInput(bad), null, bad)
})

test('table values: term, amount range and page size', () => {
  assert.equal(termText(84, 84), '84x')
  assert.equal(termText(4, 5), '4 a 5x')
  assert.equal(rangeText(300, 10000), 'R$ 300,00 a R$ 10.000,00')
  assert.equal(rangeText(null, null), 'Qualquer valor')
  assert.equal(pageSize('25', 10), 25)
  assert.equal(pageSize('7', 10), 10)
})

test('feedback: a page that already has a query or an anchor keeps them', () => {
  assert.equal(feedbackUrl('/app/x/1?v=2', 'ok:linha_salva'), '/app/x/1?v=2&f=ok%3Alinha_salva')
  assert.equal(feedbackUrl('/app/x/1?v=2#comissao', 'ok:linha_salva'), '/app/x/1?v=2&f=ok%3Alinha_salva#comissao')
})

test('fetchAll: reads page by page until a short page, and stops on error', async () => {
  const rows = Array.from({ length: 2350 }, (_, i) => i)
  const calls: [number, number][] = []
  const all = await fetchAll(async (a, b) => { calls.push([a, b]); return { data: rows.slice(a, b + 1), error: null } })
  assert.equal(all.length, 2350); assert.deepEqual(calls, [[0, 999], [1000, 1999], [2000, 2999]])
  const exact = await fetchAll(async (a, b) => ({ data: rows.slice(0, 2000).slice(a, b + 1), error: null }))
  assert.equal(exact.length, 2000)
  await assert.rejects(fetchAll(async () => ({ data: null, error: new Error('boom') })))
})

test('group payout on the table follows the group rule, like the proposal calculation', () => {
  assert.equal(percentOf('10.05', '20.000000'), '2.01')
  assert.equal(percentOf('10.05', '50'), '5.025')
  assert.equal(percentOf('5.75', '100.000000'), '5.75')
  const company = { value_kind: 'percentage', value: '10.05' }
  const stored = (g: string) => (g === 'g-cor' ? { value_kind: 'percentage', value: '3.7375' } : g === 'g-par' ? { value_kind: 'fixed_brl', value: '25.00' } : undefined)
  // MAIS VALOR: 20 % of what the company receives
  assert.deepEqual(groupPayout({ reference_kind: 'company', reference_group_id: null, distributed_pct: '20.000000' }, true, company, stored, 'g-afi'), { value_kind: 'percentage', value: '2.01' })
  // Smart: the group's own column, 100 %
  assert.deepEqual(groupPayout({ reference_kind: 'own', reference_group_id: null, distributed_pct: '100' }, true, company, stored, 'g-cor'), { value_kind: 'percentage', value: '3.7375' })
  // another group's column, fixed R$
  assert.deepEqual(groupPayout({ reference_kind: 'group', reference_group_id: 'g-par', distributed_pct: '50' }, true, company, stored, 'g-x'), { value_kind: 'fixed_brl', value: '12.5' })
  // 0 % or no item = nothing; no rule at all = the column as typed
  assert.equal(groupPayout({ reference_kind: 'company', reference_group_id: null, distributed_pct: '0.000000' }, true, company, stored, 'g-afi'), undefined)
  assert.equal(groupPayout(undefined, true, company, stored, 'g-cor'), undefined)
  assert.deepEqual(groupPayout(undefined, false, company, stored, 'g-cor'), { value_kind: 'percentage', value: '3.7375' })
})
