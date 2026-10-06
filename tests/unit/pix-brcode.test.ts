import test from 'node:test'
import assert from 'node:assert/strict'
import { crc16, pixCopyPaste, pixKey } from '../../src/lib/pix/brcode'

test('CRC16-CCITT: standard check value and the Banco Central manual example', () => {
  assert.equal(crc16('123456789'), '29B1')
  // BR Code manual example (static, no amount): the last four characters are its CRC.
  const example = '00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***6304'
  assert.equal(crc16(example), '1D3D')
})

test('keys are written as the PIX directory stores them; bad keys are refused', () => {
  assert.equal(pixKey('cpf_cnpj', '529.982.247-25'), '52998224725')
  assert.equal(pixKey('cpf_cnpj', '11.222.333/0001-81'), '11222333000181')
  assert.equal(pixKey('cpf_cnpj', '123'), null)
  assert.equal(pixKey('phone', '(68) 99955-4433'), '+5568999554433')
  assert.equal(pixKey('phone', '+55 68 99955-4433'), '+5568999554433')
  assert.equal(pixKey('email', ' Teste@Exemplo.com '), 'teste@exemplo.com')
  assert.equal(pixKey('email', 'nao-e-email'), null)
  assert.equal(pixKey('random', '123E4567-E12B-12D1-A456-426655440000'), '123e4567-e12b-12d1-a456-426655440000')
  assert.equal(pixKey('random', 'abc'), null)
  assert.equal(pixKey('outro', 'x'), null)
})

test('copia e cola: key, exact amount, plain name and city, valid CRC', () => {
  const code = pixCopyPaste({ keyType: 'email', key: 'teste@exemplo.com', amount: '1250.00', name: 'José da Silva Ação Ltda Muito Comprida', city: 'Rio Branco' })!
  assert.ok(code.startsWith('000201'))
  assert.ok(code.includes('0014br.gov.bcb.pix0117teste@exemplo.com'))
  assert.ok(code.includes('54071250.00'))
  assert.ok(code.includes('5925JOSE DA SILVA ACAO LTDA '.slice(0, 29)))
  assert.ok(code.includes('6010RIO BRANCO'))
  assert.ok(code.includes('62070503***6304'))
  assert.equal(code.slice(-4), crc16(code.slice(0, -4)))
})

test('copia e cola refuses a bad key or amount; city defaults to BRASIL', () => {
  assert.equal(pixCopyPaste({ keyType: 'email', key: 'x', amount: '10.00', name: 'A' }), null)
  assert.equal(pixCopyPaste({ keyType: 'email', key: 'a@b.co', amount: '10', name: 'A' }), null)
  assert.equal(pixCopyPaste({ keyType: 'email', key: 'a@b.co', amount: '0.00', name: 'A' }), null)
  assert.ok(pixCopyPaste({ keyType: 'email', key: 'a@b.co', amount: '10.00', name: 'A', city: null })!.includes('6006BRASIL'))
})
