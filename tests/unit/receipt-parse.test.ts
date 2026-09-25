import test from 'node:test'
import assert from 'node:assert/strict'
import { amountText, buildReceiptRows, csvDelimiter, dateText, installmentText, splitHeader } from '../../src/lib/receipts/parse'

test('amounts become exact decimal strings', () => {
  assert.equal(amountText('600,00', false), '600.00')
  assert.equal(amountText('R$ 1.234,56', false), '1234.56')
  assert.equal(amountText('11.67', false), '11.67')
  assert.equal(amountText('1234.5', false), '1234.50')
  assert.equal(amountText('600', false), '600.00')
})

test('ambiguous, over-precise, zero and negative amounts are refused, never rounded', () => {
  assert.equal(amountText('1.234', false), 'ambiguous')
  assert.equal(amountText('11,666', false), 'invalid')
  assert.equal(amountText('11.6666', false), 'invalid')
  assert.equal(amountText('0,00', false), 'invalid')
  assert.equal(amountText('-600,00', false), 'negative')
  assert.equal(amountText('abc', false), 'invalid')
  assert.equal(amountText('', false), null)
})

test('chargeback reports may print the amount as negative', () => {
  assert.equal(amountText('-600,00', true), '600.00')
  assert.equal(amountText('(600,00)', true), '600.00')
  assert.equal(amountText('600,00-', true), '600.00')
})

test('dates and installments', () => {
  assert.equal(dateText('10/09/2026'), '2026-09-10')
  assert.equal(dateText('2026-09-10T00:00:00.000Z'), '2026-09-10')
  assert.equal(dateText('31/02/2026'), 'invalid')
  assert.equal(installmentText('003'), '3')
  assert.equal(installmentText('3/120'), '3')
  assert.equal(installmentText('0'), 'invalid')
})

test('layout applied to a report with a title block, a total line and a bad row', () => {
  const sheet = splitHeader([
    ['Banco Teste - Relatório de comissão à vista'],
    [],
    ['Contrato', 'Cliente', 'Valor comissão', 'Pago em'],
    ['ADE-1', 'Maria', '600,00', '10/09/2026'],
    ['ADE-2', 'João', '599,99', ''],
    ['ADE-3', 'Ana', '1.234', ''],
    ['', '', '', ''],
    ['Total', '', '1.199,99', ''].map((v, i) => (i === 0 ? '' : v)),
  ])!
  assert.equal(sheet.headerRow, 3)
  const r = buildReceiptRows(sheet, { ade: 'Contrato', amount: 'Valor comissão', paid_on: 'Pago em' }, 'upfront')
  assert.deepEqual(r.rows, [
    { row: 4, ade: 'ADE-1', amount: '600.00', paid_on: '2026-09-10' },
    { row: 5, ade: 'ADE-2', amount: '599.99' },
  ])
  assert.deepEqual(r.issues, [{ row: 6, code: 'amount_ambiguous' }, { row: 8, code: 'ade_missing' }])
})

test('CSV delimiter comes from the whole top of the file, not from a title line', () => {
  assert.equal(csvDelimiter('Relatório de comissão\n\nContrato;Valor\nA;600,00\n'), ';')
  assert.equal(csvDelimiter('Contrato,Valor\nA,600.00\n'), ',')
  assert.equal(csvDelimiter('Contrato\tValor\nA\t600,00\n'), '\t')
})
