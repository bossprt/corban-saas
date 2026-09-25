import { test } from 'node:test'
import assert from 'node:assert/strict'
import { formatTaxId, isValidCnpj, isValidTaxId, payToText, sellerCode } from '../../src/lib/sellers'

test('sellers: CNPJ check digits, same rule as the database', () => {
  assert.equal(isValidCnpj('11.222.333/0001-81'), true)
  assert.equal(isValidCnpj('11222333000182'), false)
  assert.equal(isValidCnpj('11111111111111'), false)
  assert.equal(isValidCnpj('1122233300018'), false)
})

test('sellers: CPF or CNPJ, formatted for the screen', () => {
  assert.equal(isValidTaxId('111.444.777-35'), true)
  assert.equal(isValidTaxId('111.444.777-36'), false)
  assert.equal(isValidTaxId('11222333000181'), true)
  assert.equal(isValidTaxId('123'), false)
  assert.equal(formatTaxId('11144477735'), '111.444.777-35')
  assert.equal(formatTaxId('11222333000181'), '11.222.333/0001-81')
  assert.equal(formatTaxId(null), '')
})

test('sellers: the code is shown with three digits', () => {
  assert.equal(sellerCode(7), '007')
  assert.equal(sellerCode(79), '079')
  assert.equal(sellerCode(1234), '1234')
  assert.equal(sellerCode(null), '—')
})

test('sellers: the primary account as one line for whoever pays', () => {
  const none = { pix_key_type: null, pix_key: null, bank_code: null, bank_name: null, branch: null, account_number: null, account_digit: null, holder_name: null, holder_document: null }
  assert.equal(payToText({ ...none, transfer_method: 'pix', pix_key_type: 'email', pix_key: 'x@y.co' }), 'PIX (E-mail): x@y.co')
  assert.equal(payToText({ ...none, transfer_method: 'ted', bank_code: '104', bank_name: 'Caixa', branch: '0001', account_number: '445566', account_digit: 'X',
    holder_name: 'Empresa Ltda', holder_document: '11222333000181' }), 'TED 104 Caixa · ag. 0001 · 445566-X · favorecido: Empresa Ltda (11.222.333/0001-81)')
})
