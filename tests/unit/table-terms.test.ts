import test from 'node:test'
import assert from 'node:assert/strict'
import { acceptsTerm, readTerm, termsLabel } from '../../src/lib/commission/tableTerms'

test('table terms: typed term is whole months 1 to 999', () => {
  assert.equal(readTerm(' 84 '), 84)
  for (const v of ['', '0', 'abc', '8.4', '-6', '1000']) assert.equal(readTerm(v), null, v)
})

test('table terms: a table accepts a term inside any line range, edges included', () => {
  const r = [{ min: 6, max: 24 }, { min: 72, max: 96 }]
  assert.ok(acceptsTerm(r, 72) && acceptsTerm(r, 84) && acceptsTerm(r, 96) && acceptsTerm(r, 6))
  assert.ok(!acceptsTerm(r, 48) && !acceptsTerm(r, 120) && !acceptsTerm([], 84))
})

test('table terms: label shows the whole span or the single term', () => {
  assert.equal(termsLabel([{ min: 6, max: 24 }, { min: 72, max: 96 }]), '6 a 96')
  assert.equal(termsLabel([{ min: 84, max: 84 }, { min: 84, max: 84 }]), '84')
  assert.equal(termsLabel([]), '—')
})
