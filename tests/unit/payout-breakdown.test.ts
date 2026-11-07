import test from 'node:test'
import assert from 'node:assert/strict'
import { batchFooter, breakdownView } from '../../src/lib/payout/breakdown'

const contract = (amount: string) => ({ proposal_id: 'p', ade: '1', client: 'C', amount })
const item = (kind: string, amount: string, description: string | null = null) => ({ kind, amount, description, effective_on: null })

test('breakdownView: contracts + others = total, exact decimals', () => {
  const v = breakdownView({ contracts: [contract('1000.00'), contract('234.56')], others: [item('advance', '-200.00'), item('bonus', '50.00'), item('carry_in', '10.00')] }, '1094.56')
  assert.deepEqual(v, { contractsTotal: '1234.56', othersTotal: '-140.00', total: '1094.56', difference: '0.00', hasDifference: false, contractCount: 2 })
})

test('breakdownView: 0.1 + 0.2 has no float drift', () => {
  const v = breakdownView({ contracts: [contract('0.10'), contract('0.20')], others: [] }, '0.30')
  assert.equal(v.hasDifference, false)
})

test('breakdownView: a missing part shows as difference', () => {
  const v = breakdownView({ contracts: [contract('90.00')], others: [] }, '100.00')
  assert.equal(v.hasDifference, true)
  assert.equal(v.difference, '10.00')
})

test('batchFooter: only paid lines; other items listed with the person', () => {
  const f = batchFooter([
    { holder: 'Ana', amount: '800.00', status: 'paid', contracts: [contract('1000.00')], others: [item('advance', '-200.00', 'vale')] },
    { holder: 'Bia', amount: '42.00', status: 'paid', contracts: [contract('60.00')], others: [item('debt_deduction', '-18.00')] },
    { holder: 'Cris', amount: '150.00', status: 'reversed', contracts: [], others: [] },
  ])
  assert.equal(f.contractsTotal, '1060.00')
  assert.equal(f.othersTotal, '-218.00')
  assert.equal(f.paidTotal, '842.00')
  assert.equal(f.hasDifference, false)
  assert.deepEqual(f.others.map(o => `${o.holder}:${o.label}:${o.amount}`), ['Ana:Vale:-200.00', 'Bia:Desconto do negativo:-18.00'])
})
