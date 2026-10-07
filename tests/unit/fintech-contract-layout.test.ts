import test from 'node:test'
import assert from 'node:assert/strict'
import { CONTRACT_LAYOUTS, parseContractSheet } from '../../src/lib/imports/contract-layout'

const fintech = CONTRACT_LAYOUTS.find(l => l.key === 'fintech')!
// The header of the FINTECH CORBAN report as the bank exports it; the data row is made up.
const HEADER = ['Id', 'IdTableComissao', 'Data', 'DataFinalização', 'Status', 'SubStatus', 'CpfCliente', 'NomeCliente', 'DataNascimento',
  'CelularCliente', 'IdFintech', 'NomeFintech', 'IdCorban', 'NomeCorban', 'NomeGerente', 'NomeSupervisor', 'NomeConsultor', 'LoginConsultor',
  'CpfConsultor', 'Prazo', 'Prazo Total', 'Prazo Quitado', 'ValorLiquido', 'ValorOperacao', 'ValorParcela', 'Tabela', 'TipoProduto', 'ValorTotal',
  'EntranteInss', 'Token', 'Matricula', 'Convenio', 'DescBanco', 'DataQuitacao', 'Uf', 'UfDigitador', 'StatusAnuencia', 'PrazoLimiteAnuencia']
const row = (status: string, tableId: string) => ['4184094', tableId, '01/10/2026', '02/10/2026', status, '', '529.982.247-25', 'CLIENTE TESTE',
  '1968-10-07', '68999990000', '1', 'X', '2', 'Y', 'G', 'S', 'C', 'login', '00000000000', '108', '', '', '23454.58', '24269.51', '534',
  ' NORMAL- TX 1,85', 'Inss', '57672', 'Não', '', '', '', '', '', '', 'AC', 'Sim', '']

test('FINTECH report: every column is known, the table comes from IdTableComissao, FINALIZADA / PAGA is paid', () => {
  const r = parseContractSheet([HEADER, row('FINALIZADA / PAGA', '991')], '2026-10-07', fintech)
  assert.deepEqual(r.map.issues, [])
  const l = r.lines[0]
  assert.deepEqual(l.issues, [])
  assert.equal(l.ade, '4184094')
  assert.equal(l.table, 'NOVO - INSS - FP - NORMAL- TX 1,85')
  assert.equal(l.term, 108)
  assert.equal(l.released, '23454.58')
  assert.equal(l.requested, '24269.51')
  assert.equal(l.stage, 'paid')
  assert.equal(l.paidOn, '2026-10-02')
  assert.equal(l.cpf, '52998224725')
  assert.equal(l.client.profile.birth_date, '1968-10-07')
  assert.equal(l.seller, '')
})

test('FINTECH report: an unknown status is never guessed; an unknown table id stays as text and is not found', () => {
  const unknown = parseContractSheet([HEADER, row('EM ANDAMENTO X', '991')], '2026-10-07', fintech).lines[0]
  assert.ok(unknown.issues.includes('stage_unknown'))
  const other = parseContractSheet([HEADER, row('FINALIZADA / PAGA', '9999')], '2026-10-07', fintech).lines[0]
  assert.equal(other.table, '9999')
})
