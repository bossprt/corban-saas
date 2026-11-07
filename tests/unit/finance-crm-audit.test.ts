import { test } from 'node:test'
import assert from 'node:assert/strict'
import { brl, brlCents, centsToDecimal, toCents } from '../../src/lib/finance/labels'
import { buildBulkItems, bulkReceiptError, totalCents } from '../../src/lib/receipts/bulk'

const A = '00000000-0000-4000-8000-000000000001'
const B = '00000000-0000-4000-8000-000000000002'

test('money in cents without floating point', () => {
  assert.equal(toCents('1234.56'), 123456)
  assert.equal(toCents('-0.10'), -10)
  assert.equal(toCents('7'), 700)
  assert.equal(toCents('0.1'), 10)
  assert.equal(toCents(null), 0)
  assert.equal(centsToDecimal(123456), '1234.56')
  assert.equal(centsToDecimal(-5), '-0.05')
  assert.equal(centsToDecimal(0), '0.00')
  // 0.1 + 0.2 in floats is 0.30000000000000004; in cents it is exact.
  assert.equal(centsToDecimal(toCents('0.10') + toCents('0.20')), '0.30')
  assert.equal(brlCents(123456789), 'R$ 1.234.567,89')
  assert.equal(brl('99999999999.99'), 'R$ 99.999.999.999,99')
  assert.equal(brl(null), '—')
})

test('bulk receipt items', () => {
  const amounts: Record<string, string> = { [A]: '600,00', [B]: '1.234,5' }
  const r = buildBulkItems([A, B, A, 'x'], id => amounts[id])
  assert.deepEqual(r, { ok: true, items: [{ proposal_id: A, amount: '600.00' }, { proposal_id: B, amount: '1234.50' }] })
  assert.equal(buildBulkItems([], () => '1').ok, false)
  assert.equal(buildBulkItems([A], () => '0,00').ok, false)
  assert.equal(buildBulkItems([A], () => 'abc').ok, false)
  assert.equal(totalCents(['600.00', '1234.50']), 183450)
})

test('bulk receipt refusal names the contract', () => {
  assert.equal(bulkReceiptError('bulk_receipt_item:ADE-9:manual_receipt_duplicate'), 'Contrato ADE-9: o recebimento à vista já foi registrado. Nada foi registrado; corrija e tente de novo.')
  assert.match(bulkReceiptError('not_authorized'), /^Seu perfil não pode/)
})
