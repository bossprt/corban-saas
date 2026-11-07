import test from 'node:test'
import assert from 'node:assert/strict'
import { activeCount, contractFilters, listSearch, pipelineFilters } from '../../src/lib/contracts/listFilters'
import { closesContract, needsReason, validReason } from '../../src/lib/pipeline/stageReason'

const from = (o: Record<string, string>) => (k: string) => o[k] ?? ''
const ID = '0b6f4d2e-1c3a-4e5f-8a9b-0c1d2e3f4a5b'

test('list search: name or contract number; a CPF never goes to the query', () => {
  assert.equal(listSearch('  João   da Silva '), 'João da Silva')
  assert.equal(listSearch('123.456.789-09'), '')
  assert.equal(listSearch('12345678909'), '')
  assert.equal(listSearch('ADE 1234'), 'ADE 1234')
  assert.equal(listSearch('x'.repeat(100)).length, 80)
})

test('contract filters: malformed values are dropped, valid ones kept', () => {
  const f = contractFilters(from({ q: 'joao', de: '2026-11-01', ate: '2026-13-40', banco: 'none', convenio: 'abc', vendedor: ID.toUpperCase(), grupo: ID,
    cliente: 'x', comissao: 'calculada', repasse: 'hack', pago_de: '2026-11-06', encerradas: 'yes', alterado: '1' }), 'paid')
  assert.equal(f.q, 'joao')
  assert.equal(f.de, '2026-11-01')
  assert.equal(f.ate, '')
  assert.equal(contractFilters(from({ de: '2026-02-30' }), '').de, '')
  assert.equal(f.banco, 'none')
  assert.equal(f.convenio, '')
  assert.equal(f.vendedor, ID)
  assert.equal(f.grupo, ID)
  assert.equal(f.cliente, '')
  assert.equal(f.comissao, 'calculada')
  assert.equal(f.repasse, '')
  assert.equal(f.pago_de, '2026-11-06')
  assert.equal(f.encerradas, '')
  assert.equal(f.alterado, '1')
  assert.equal(f.situacao, 'paid')
})

test('pipeline filters: search, client id and seller (or none)', () => {
  assert.deepEqual(pipelineFilters(from({ q: ' maria ', cliente: ID, vendedor: 'none' })), { q: 'maria', cliente: ID, vendedor: 'none' })
  assert.deepEqual(pipelineFilters(from({ cliente: '1', vendedor: 'drop' })), { q: '', cliente: '', vendedor: '' })
})

test('active filter count skips the search box', () => {
  assert.equal(activeCount({ q: 'x', de: '2026-11-01', banco: '' }, ['q']), 1)
})

test('stage reason: Pendência, Recusada and Cancelada need a reason; only the last two close the contract', () => {
  assert.ok(needsReason('pending_external') && needsReason('rejected') && needsReason('cancelled'))
  assert.ok(!needsReason('paid') && !needsReason('submitted') && !needsReason(null))
  assert.ok(closesContract('rejected') && closesContract('cancelled') && !closesContract('pending_external'))
  assert.ok(validReason('  doc ') && !validReason('  ok ') && !validReason('x'.repeat(501)))
})
