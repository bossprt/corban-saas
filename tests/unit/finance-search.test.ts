import test from 'node:test'
import assert from 'node:assert/strict'
import { entrySearchFilter, foldText } from '../../src/lib/finance/search'

test('finance search: empty or only symbols searches nothing', () => {
  assert.equal(entrySearchFilter(''), null)
  assert.equal(entrySearchFilter('   '), null)
  assert.equal(entrySearchFilter('(),*'), null)
})

test('finance search: text looks in the folded description, counterpart and document', () => {
  assert.equal(entrySearchFilter(' Aluguel '), 'search_text.like."*aluguel*"')
})

test('finance search: accents and case do not matter', () => {
  assert.equal(foldText('Fictícia AÇÃO Ônibus'), 'ficticia acao onibus')
  assert.equal(entrySearchFilter('FICTÍCIA'), entrySearchFilter('ficticia'))
})

test('finance search: amount in any common writing also matches the value', () => {
  for (const v of ['5000', '5.000', '5.000,00', '5000,00', 'R$ 5.000,00']) assert.ok(entrySearchFilter(v)!.endsWith(',amount.eq.5000.00'), v)
  assert.ok(entrySearchFilter('1.250,5')!.endsWith(',amount.eq.1250.50'))
})

test('finance search: filter syntax in the text cannot change the query', () => {
  const f = entrySearchFilter('x),status.eq.open,(a"b')!
  assert.ok(!/[()]/.test(f.replace(/like\."[^"]*"/g, '')))
  assert.equal(f.split(',').length, 1)
  assert.ok(!f.includes('amount'))
})
