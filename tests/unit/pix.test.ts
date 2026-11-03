import test from 'node:test'
import assert from 'node:assert/strict'
import { crc16, pixAmount, pixPayload } from '../../src/lib/pix'

// Fictitious receiver: the real key is only in the production database.
const base = { key: '12345678909', name: 'Fulano de Tal', city: 'Rio Branco', amount: '399,90', txid: 'MAISVALOR202611' }

test('crc16 CCITT-FALSE reference value', () => {
  assert.equal(crc16('123456789'), '29B1')
})

test('amount keeps two decimals without floating point', () => {
  assert.equal(pixAmount('399,90'), '399.90')
  assert.equal(pixAmount('399.9'), '399.90')
  assert.equal(pixAmount('399'), '399.00')
  assert.throws(() => pixAmount('399,999'))
  assert.throws(() => pixAmount('-1'))
})

test('payload carries the fields of a static Pix and a valid CRC', () => {
  const p = pixPayload(base)
  assert.ok(p.startsWith('000201'))
  assert.ok(p.includes('0014br.gov.bcb.pix011112345678909'))
  assert.ok(p.includes('5406399.90'))
  assert.ok(p.includes('5802BR5913FULANO DE TAL6010RIO BRANCO'))
  assert.ok(p.includes('62190515MAISVALOR202611'))
  assert.equal(p.slice(-4), crc16(p.slice(0, -4)))
})

test('name and city lose accents and are cut to the limits', () => {
  const p = pixPayload({ ...base, name: 'José Ação da Silva Braguinha', city: 'São José do Rio Pardo' })
  assert.ok(p.includes('5925JOSE ACAO DA SILVA BRAGUI'))
  assert.ok(p.includes('6015SAO JOSE DO RIO'))
})

test('missing receiver data is refused', () => {
  assert.throws(() => pixPayload({ ...base, key: ' ' }), /pix_invalid_receiver/)
  assert.throws(() => pixPayload({ ...base, city: '' }), /pix_invalid_receiver/)
})
