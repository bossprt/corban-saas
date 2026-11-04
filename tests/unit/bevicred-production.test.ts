import test from 'node:test'
import assert from 'node:assert/strict'
import { bevicredSheet, bevicredStage, bevicredTableName, latestByAde, sameBank, type BevicredRow } from '../../src/lib/imports/bevicred-production'
import { CONTRACT_LAYOUTS, layoutsFor, parseContractSheet } from '../../src/lib/imports/contract-layout'

// Bevicred "produção sintética" as contract lines (owner request 03/11/2026). Fictitious data in the shape of the probe.
const row = (o: Partial<BevicredRow>): BevicredRow => ({
  financeira: 'C6 BANK', numeroAde: '900000101', cpfCliente: '000.000.001-91', nomeCliente: 'CLIENTE FICTICIO', tabela: null,
  status: 'Pago', dataPagtoCliente: '2026-10-20', dataStatus: '2026-10-20', prazo: '108', valoremprestimo: '4200.00',
  valorLiquido: '4100.50', vlrParcela: '98.10', nomeFormaContrato: 'NOVO', descricaoOperacao: 'INSS ML DWEB Tkt ate 6k Inval-DWeb-ML',
  codigoParceiro: 'SP18-000001', nomeParceiro: 'PARCEIRO FICTICIO', dataNascimento: '1960-05-01', nomeMae: 'MAE FICTICIA',
  nomePai: null, rg: '123456', celular: null, fone: null, beneficio: '1234567890', nomeConvenio: 'INSS', ...o,
})
const layout = CONTRACT_LAYOUTS.find(l => l.key === 'bevicred')!

test('Bevicred: status to stage, table name without the term, bank names', () => {
  assert.equal(bevicredStage('Pago'), 'Paga')
  assert.equal(bevicredStage('CANCELADO'), 'Cancelada')
  assert.equal(bevicredStage('PENDENTE'), 'Pendência')
  assert.equal(bevicredStage('ANDAMENTO'), 'Em análise no banco')
  assert.equal(bevicredStage(''), 'Em análise no banco')
  assert.equal(bevicredTableName('C6 BANK NOVO INSS ML TKT ATE 6K WEB 108X'), 'C6 BANK NOVO INSS ML TKT ATE 6K WEB')
  assert.equal(bevicredTableName('DAYCOVAL GOV ACRE NOVO TAB 5 DIG 60X'), 'DAYCOVAL GOV ACRE NOVO TAB 5 DIG')
  assert.ok(sameBank('C6 BANK', 'C6 Bank'))
  assert.ok(sameBank('DAYCOVAL', 'Daycoval'))
  assert.ok(!sameBank('BB MAIS', 'Banco do Brasil'))
  assert.ok(!sameBank('', 'Daycoval'))
})

test('Bevicred: the same ADE on several days keeps the latest status', () => {
  const rows = latestByAde([
    { credential: 'Sub', row: row({ status: 'ANDAMENTO', dataStatus: '2026-10-10' }) },
    { credential: 'Sub', row: row({ status: 'Pago', dataStatus: '2026-10-20' }) },
    { credential: 'Sub', row: row({ numeroAde: '900000102', dataStatus: '2026-10-01' }) },
  ])
  assert.equal(rows.length, 2)
  assert.equal(rows.find(r => r.row.numeroAde === '900000101')?.row.status, 'Pago')
})

test('Bevicred: lines read by the contract import, with client data and the meta to remember choices', () => {
  const sheet = bevicredSheet([
    { credential: 'Sub', row: row({ tabela: 'C6 BANK NOVO INSS ML INVALIDEZ TKT ATE 6K WEB 108X' }) },
    { credential: 'Mais Valor', row: row({ numeroAde: '900000103', status: 'Pago', dataPagtoCliente: null, dataStatus: '2026-10-22', prazo: '0', valoremprestimo: null, valorLiquido: '0.00' }) },
  ])
  const parsed = parseContractSheet(sheet.rows, '2026-11-03', layout)
  assert.deepEqual(parsed.map.issues, [])
  const [a, b] = parsed.lines
  assert.deepEqual([a.cpf, a.ade, a.term, a.requested, a.released, a.installment, a.typeKey, a.stage, a.paidOn, a.table, a.issues],
    ['00000000191', '900000101', 108, '4200.00', '4100.50', '98.10', 'novo', 'paid', '2026-10-20', 'C6 BANK NOVO INSS ML INVALIDEZ TKT ATE 6K WEB', []])
  assert.equal(a.client.profile.mother_name, 'MAE FICTICIA')
  assert.equal(a.client.profile.birth_date, '1960-05-01')
  assert.deepEqual(a.client.registration, { number: '1234567890', agency: 'INSS' })
  // Paid without "dataPagtoCliente": the status date; term 0 and no amount are line errors (the line is left out).
  assert.equal(b.paidOn, '2026-10-22')
  assert.ok(b.issues.includes('term_invalid') && b.issues.includes('amount_required'))
  assert.deepEqual(sheet.meta.map(m => [m.credential, m.institution, m.operationKey, m.partnerCode]), [
    ['Sub', 'C6 BANK', 'inss ml dweb tkt ate 6k inval-dweb-ml', 'SP18-000001'],
    ['Mais Valor', 'C6 BANK', 'inss ml dweb tkt ate 6k inval-dweb-ml', 'SP18-000001'],
  ])
})

test('import layouts: only the banks the company has, Bevicred only with a credential', () => {
  const keys = (banks: string[], bevicred: boolean) => layoutsFor(banks, bevicred).map(l => l.key)
  assert.deepEqual(keys(['C6 Bank', 'Daycoval'], true), ['bevicred'])
  assert.deepEqual(keys(['C6 Bank'], false), [])
  assert.deepEqual(keys(['NASP', 'Hope', 'Valor Financiamento'], false), ['nasp', 'hope', 'valor'])
  assert.deepEqual(layoutsFor(['Daycoval'], true, ['Bevicred', 'Efetivamais']).map(l => l.key), ['efetivamais', 'bevicred'])
  assert.deepEqual(layoutsFor(['Daycoval'], false, ['Efetiva Kessy']).map(l => l.key), [])
})
