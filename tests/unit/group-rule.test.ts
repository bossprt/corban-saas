import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizePct, parseReference, pctText, referenceValue } from '../../src/lib/commission/groupRule'

test('group rule: percentages are decimal text from 0 to 100', () => {
  assert.equal(normalizePct('100'), '100')
  assert.equal(normalizePct('100,00'), '100')
  assert.equal(normalizePct(' 65,5 '), '65.5')
  assert.equal(normalizePct('2.250000'), '2.25')
  assert.equal(normalizePct('0'), '0')
  assert.equal(normalizePct('007'), '7')
  assert.equal(normalizePct('0,000001'), '0.000001')
  for (const bad of ['100,01', '101', '250', '-1', '1e2', '', 'abc', '1,2,3', '0,0000001', '1.5.2']) assert.equal(normalizePct(bad), null, bad)
})

test('group rule: column choice round-trips and rejects anything else', () => {
  const id = '00000000-0000-4000-8000-0000000c0601'
  assert.deepEqual(parseReference('own'), { reference: 'own', group: null })
  assert.deepEqual(parseReference('company'), { reference: 'company', group: null })
  assert.deepEqual(parseReference(`group:${id}`), { reference: 'group', group: id })
  assert.equal(referenceValue('group', id), `group:${id}`)
  for (const bad of ['', 'group:', 'group:x', 'Own', 'group:00000000-0000-4000-8000-0000000c060']) assert.equal(parseReference(bad), null, bad)
})

test('group rule: database percentages are shown in pt-BR with at least 2 decimals', () => {
  assert.equal(pctText('100.000000'), '100,00')
  assert.equal(pctText('1.250000'), '1,25')
  assert.equal(pctText('0.500000'), '0,50')
  assert.equal(pctText('2.123456'), '2,123456')
  assert.equal(pctText(null), '')
})
