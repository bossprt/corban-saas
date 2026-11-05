import test from 'node:test'
import assert from 'node:assert/strict'
import { entrySearchFilter } from '../../src/lib/finance/search'

test('finance search: empty or only symbols searches nothing', () => {
  assert.equal(entrySearchFilter(''), null)
  assert.equal(entrySearchFilter('   '), null)
  assert.equal(entrySearchFilter('(),*'), null)
})

test('finance search: text looks in description, counterpart and document', () => {
  assert.equal(entrySearchFilter(' aluguel '), 'description.ilike."*aluguel*",counterpart.ilike."*aluguel*",document.ilike."*aluguel*"')
})

test('finance search: amount in any common writing also matches the value', () => {
  for (const v of ['5000', '5.000', '5.000,00', '5000,00', 'R$ 5.000,00']) assert.ok(entrySearchFilter(v)!.endsWith(',amount.eq.5000.00'), v)
  assert.ok(entrySearchFilter('1.250,5')!.endsWith(',amount.eq.1250.50'))
})

test('finance search: filter syntax in the text cannot change the query', () => {
  const f = entrySearchFilter('x),status.eq.open,(a"b')!
  assert.ok(!/[()]/.test(f.replace(/ilike\."[^"]*"/g, '')))
  assert.equal(f.split(',').length, 3)
  assert.ok(!f.includes('amount'))
})
