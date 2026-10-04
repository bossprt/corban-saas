import test from 'node:test'
import assert from 'node:assert/strict'
import { mapContractHeader, matchTable, parseContractLine, parseContractSheet } from '../../src/lib/imports/contract-layout'

// A valid CPF built for tests (no real person): 529.982.247-25.
const CPF = '52998224725'
const TODAY = '2026-10-02'
const HEAD = ['CPF *', 'Nome', 'Tabela *', 'Prazo (meses) *', 'Valor liberado', 'Nº contrato/ADE', 'Etapa', 'Pago ao cliente em']

test('template header maps every column; nothing missing', () => {
  const m = mapContractHeader(HEAD)
  assert.deepEqual(m.issues, [])
  assert.equal(m.columns.cpf, 0)
  assert.equal(m.columns.ade, 5)
  assert.equal(m.columns.paidOn, 7)
})

test('a sheet without optional columns is accepted (owner rule)', () => {
  const m = mapContractHeader(['CPF', 'Tabela', 'Prazo', 'Valor solicitado'])
  assert.deepEqual(m.issues, [])
})

test('missing identification columns refuse the file', () => {
  const codes = mapContractHeader(['Nome', 'Valor da parcela']).issues.map(i => i.column)
  assert.deepEqual(codes, ['CPF', 'Tabela', 'Prazo (meses)', 'Valor liberado ou Valor solicitado'])
})

test('unknown money columns refuse the file; unknown text columns are only listed', () => {
  const m = mapContractHeader([...HEAD, 'Valor comissão', 'Matrícula'])
  assert.deepEqual(m.issues, [{ code: 'unknown_money_column', column: 'Valor comissão' }])
  assert.deepEqual(m.ignored, ['Matrícula'])
})

test('line: Excel number CPF without leading zero, money and Brazilian date', () => {
  const { columns } = mapContractHeader(HEAD)
  const l = parseContractLine(['1234567890', 'Teste', 'Temporário (8 a 18 meses)', '12', '1.500,50', '0099', 'paga', '01/10/2026'], columns, 2, TODAY)
  assert.equal(l.cpf, '01234567890')
  assert.equal(l.released, '1500.50')
  assert.equal(l.stage, 'paid')
  assert.equal(l.paidOn, '2026-10-01')
  assert.equal(l.ade, '0099')
})

test('line issues: invalid CPF, no amount, future paid date, paid without date', () => {
  const { columns } = mapContractHeader(HEAD)
  assert.deepEqual(parseContractLine(['11111111111', '', 'T', '12', '', '', '', ''], columns, 2, TODAY).issues, ['cpf_invalid', 'amount_required'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '10', '', 'paga', '03/10/2026'], columns, 2, TODAY).issues, ['paid_on_invalid'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '10', '', 'paga', ''], columns, 2, TODAY).issues, ['paid_on_required'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '0', '10', '', 'xpto', ''], columns, 2, TODAY).issues, ['term_invalid', 'stage_unknown'])
  assert.deepEqual(parseContractLine([CPF, '', 'T', '12', '1.5.0', '', '', ''], columns, 2, TODAY).issues, ['amount_invalid'])
})

test('sheet: blank header issues stop before lines; lines numbered as in Excel', () => {
  const s = parseContractSheet([HEAD, [CPF, 'A', 'T', '12', '100', '', '', '']], TODAY)
  assert.equal(s.lines[0].line, 2)
  assert.equal(parseContractSheet([['Nome']], TODAY).lines.length, 0)
})

test('table match: exact, by the end of the bank name, ambiguous, none', () => {
  const tables = [
    { name: 'NASP - Gov. Acre - Temporário (4 a 7 meses)' },
    { name: 'NASP - Gov. Acre - Temporário (8 a 18 meses)' },
    { name: 'NASP - Gov. Acre - COMPRA NORMAL' },
    { name: 'NASP - Pref. X - COMPRA NORMAL' },
  ]
  assert.equal(matchTable('temporario (8 a 18 meses)', tables), tables[1])
  assert.equal(matchTable('NASP - Gov. Acre - COMPRA NORMAL', tables), tables[2])
  assert.equal(matchTable('COMPRA NORMAL', tables), 'ambiguous')
  assert.equal(matchTable('Legado', tables), 'none')
})

test('table match: the Governo do Acre name and the Prefeitura name of the same bank stay apart', () => {
  const tables = [
    { name: 'NASP - Gov. Acre - Temporário (4 a 7 meses)' },
    { name: 'NASP - Pref. Rio Branco - Prefeitura Temporário (4 a 7 meses)' },
    { name: 'NASP - Gov. Acre - Normal - Efetivo / Pensionista' },
  ]
  assert.equal(matchTable('Temporário (4 a 7 meses)', tables), tables[0])
  assert.equal(matchTable('Prefeitura Temporário (4 a 7 meses)', tables), tables[1])
  assert.equal(matchTable('Normal - Efetivo / Pensionista', tables), tables[2])
})
