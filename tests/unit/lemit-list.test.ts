import { test } from 'node:test'
import assert from 'node:assert/strict'
import { lemitColumns, lemitLine, localPhone, parseDdds } from '../../src/lib/imports/lemit-list'

// The Lemit "Não Perturbe SP" file: only the chosen area codes are kept (fictitious phones).
test('lemit list: header, area codes, phones and dates', () => {
  const cols = lemitColumns('phone;created_at;valid_at')!
  assert.deepEqual(cols, { phone: 0, valid: 2, delimiter: ';' })
  assert.equal(lemitColumns('nome;cidade'), null)
  assert.deepEqual(parseDdds('68, 69 92;1'), ['68', '69', '92'])
  assert.equal(localPhone('5568999990000'), '68999990000')
  assert.equal(localPhone('6832240000'), '6832240000')
  assert.equal(localPhone('123'), null)
  const ddds = new Set(['68'])
  assert.deepEqual(lemitLine('68999990000;2024-01-02;2024-02-01', cols, ddds), { phone: '68999990000', valid_from: '2024-02-01' })
  assert.equal(lemitLine('11999990000;2024-01-02;2024-02-01', cols, ddds), null)
  assert.deepEqual(lemitLine('68999990001;2024-01-02;01/02/2024', cols, ddds), { phone: '68999990001', valid_from: '2024-02-01' })
  assert.deepEqual(lemitLine('68999990002;;', cols, ddds), { phone: '68999990002', valid_from: null })
})
