import test from 'node:test'
import assert from 'node:assert/strict'
import { readSmartFile } from '../../src/lib/imports/smart-file'
import { bevicredGridRows, bevicredTableRows } from '../../src/lib/imports/bevicred-table'
import { mapSmartCommercialRows } from '../../src/lib/imports/smart-commercial'

// Layout of the Bevicred portal commission table (30/10/2026): HTML saved as .xls, ISO-8859-1, two header rows.
// Fictitious partner, codes and values.
type Line = { code: string; date: string; name: string; rate: [string, string]; term: string; total: string; vista: string; deferred?: string; monthly?: string; form?: string; bank?: string }
const td = (s: string) => `<td>${s}</td>`
const line = (l: Line) => `<tr>${[
  '900001', l.code, l.date, l.name, l.form ?? '', l.rate[0], l.rate[1], l.term, l.total,
  l.bank ?? '0.00', '0.00', '0.00', '0.00', l.vista, l.deferred ?? '0.00', l.monthly ?? '0.00',
].map(td).join('')}</tr>`
const page = (lines: Line[]) => `<table id="parceirotabelacomissao" class="table" border="1"><thead>
<tr><th colspan="14">C&oacute;digo Parceiro: SUB00-000000 - PARCEIRO FICTICIO</th></tr>
<tr><th rowspan="2">C&oacute;digo</th><th rowspan="2">Descri&ccedil;&atilde;o Banco</th><th rowspan="2">Data de Altera&ccedil;&atilde;o</th><th rowspan="2">Conv&ecirc;nio</th><th rowspan="2">Forma Contrato</th><th colspan="2">Taxa</th><th rowspan="2">Prazo</th><th rowspan="2">Comiss&atilde;o Total</th><th colspan="4">Comiss&atilde;o Banco</th><th colspan="3">Comiss&atilde;o Bevicred</th></tr>
<tr><th>Inicial</th><th>Final</th><th>Vista</th><th>Antecipado</th><th>Diferido Total</th><th>Diferido M&ecirc;s</th><th>Vista</th><th>Diferido Total</th><th>Diferido Mensal</th></tr>
</thead><tbody>${lines.map(line).join('\n')}</tbody></table>`
const latin1 = (s: string) => Uint8Array.from([...s].map(c => c.charCodeAt(0) & 0xff))

const REFIN: Line = { code: '220001', date: '2026-09-01', name: 'C6 BANK DIGITAL INSS REFIN 1 (+90D CARENCIA) WEB 108X', rate: ['1.85', '1.85'], term: '108', total: '10.05', vista: '10.05' }
const NOVO: Line = { code: '210001', date: '2026-10-28', name: 'C6 BANK NOVO INSS ML TKT ATE 6K WEB 96X', rate: ['1.85', '1.85'], term: '96', total: '9.25', vista: '9.25', bank: '12.00' }
const PORT: Line = { code: '230001', date: '2026-08-10', name: 'C6 BANK INSS PORTABILIDADE TX 1,850~1,68 NORMAL WEB 1 A 108X', rate: ['1.85', '1.68'], term: '1 a 108', total: '0.00', vista: '0.00' }
const RP: Line = { code: '240001', date: '2026-08-10', name: 'C6 BANK INSS REFIN DA PORTABILIDADE TX 1,85~1,78 (+30D CAR) LIQ NORMAL WEB 84X', rate: ['1.85', '1.85'], term: '84', total: '4.50', vista: '4.50' }

test('bevicred table: the HTML ".xls" in ISO-8859-1 is read; the term leaves the name; bank columns are not read', async () => {
  const r = await readSmartFile(latin1(page([REFIN, NOVO, PORT, RP])), 'tabela.xls')
  assert.equal(r.format, 'bevicred')
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.rows[0], ['Convênio', 'Tabela', 'Código no banco', 'Vigência inicial', 'Tipo de contrato', 'Prazo inicial', 'Prazo final', 'Taxa', 'À vista', 'Diferido'])
  assert.deepEqual(r.rows[1], ['INSS', 'C6 BANK DIGITAL INSS REFIN 1 (+90D CARENCIA) WEB', '220001', '2026-09-01', 'refinanciamento', '108', '108', '1.85', '10.05', ''])
  assert.deepEqual(r.rows[2].slice(4), ['novo', '96', '96', '1.85', '9.25', '']) // the bank's 12.00 is Bevicred's money, not the sub's
  assert.deepEqual(r.rows[3].slice(1, 9), ['C6 BANK INSS PORTABILIDADE TX 1,850~1,68 NORMAL WEB', '230001', '2026-08-10', 'portabilidade', '1', '108', '', '0.00'])
  assert.equal(r.rows[4][4], 'refin_portabilidade')
})

test('bevicred table: with the bank chosen, it becomes commission lines of the Corban (à vista only, no deferred)', async () => {
  const r = await readSmartFile(latin1(page([REFIN, PORT])), 'tabela.xls')
  const T = (id: string, name: string, tech_key: string) => ({ id, name, tech_key })
  const m = mapSmartCommercialRows(r.rows.map((x, i) => [i ? 'C6 Bank' : 'Banco', ...x]), {
    contractTypes: [T('t-r', 'Refinanciamento', 'refinanciamento'), T('t-p', 'Portabilidade', 'portabilidade')],
    groups: [], components: [T('c-up', 'À Vista', 'upfront'), T('c-df', 'Diferido', 'deferred')], defaultBase: 'BRUTO',
  })
  assert.deepEqual(m.issues, [])
  assert.equal(m.summary.expandedRows, 1 + 108)
  const refin = m.rows[0]
  assert.equal(refin.bank_name, 'C6 Bank')
  assert.equal(refin.rate, '1.85')
  assert.deepEqual(refin.components.map(c => [c.component_type_id, c.value_kind, c.received_value]), [['c-up', 'percentage', '10.05']])
  assert.equal(m.rows[1].rate, null) // portability rate range: no single rate
  assert.deepEqual(m.rows[1].components, []) // 0,00 = nothing to receive
})

test('bevicred table: anything it cannot read safely refuses the whole file', () => {
  const err = (l: Line) => { const r = bevicredTableRows(page([REFIN, l])); return 'error' in r ? r.error : 'ok' }
  assert.equal(err({ ...REFIN, name: 'C6 BANK CARTAO BENEFICIO WEB 96X' }), 'bevicred_unknown_contract_type')
  assert.equal(err({ ...REFIN, name: 'C6 BANK NOVO SIAPE WEB 96X' }), 'bevicred_unknown_agreement')
  assert.equal(err({ ...REFIN, total: '11.05' }), 'bevicred_total_mismatch')
  assert.equal(err({ ...REFIN, monthly: '0.10' }), 'bevicred_monthly_deferred')
  assert.equal(err({ ...REFIN, form: 'Físico' }), 'bevicred_contract_form') // a type it does not know
  assert.equal(err({ ...REFIN, total: '10.05', vista: '9.05', deferred: '1.00' }), 'ok') // deferred counts in the total
  const noBevicred = page([REFIN]).replace(/Comiss&atilde;o Bevicred/, 'Outra')
  assert.equal(('error' in bevicredTableRows(noBevicred)), true)
})

test('any other HTML named .xls is still refused', async () => {
  const r = await readSmartFile(new TextEncoder().encode('<table><tr><td>Banco</td><td>Taxa</td></tr><tr><td>X</td><td>1</td></tr></table>'), 'x.xls')
  assert.equal(r.issues[0].code, 'html_disguised_as_excel')
})

// Daycoval Gov. Acre layout (30/10/2026), as Excel shows it after "save as .xlsx": a title row, merged headers repeated,
// the contract type in "Forma Contrato", dates as timestamps. Fictitious partner, codes and values.
const DAY_TOP = ['Código', 'Descrição Banco', 'Data de Alteração', 'Convênio', 'Forma Contrato', 'Taxa', 'Taxa', 'Prazo', 'Comissão', 'Comissão', 'Diferido', 'Diferido']
const DAY_SUB = ['Código', 'Descrição Banco', 'Data de Alteração', 'Convênio', 'Forma Contrato', 'Total', 'Vista', 'Prazo', 'Total', 'Vista', 'Total', 'Mensal']
const day = (name: string, form: string, rate: [string, string], term: string, total: string, vista: string, monthly = '0.00') =>
  ['900100', '760001', '2026-10-22T00:00:00.000Z', name, form, rate[0], rate[1], term, total, vista, '0.00', monthly]
const DAY = [
  ['Código Parceiro: SUB00-000000 - PARCEIRO FICTICIO'], DAY_TOP, DAY_SUB,
  day('DAYCOVAL GOV ACRE NOVO TAB 1 DIG 96X', 'NOVO', ['2.40', '2.40'], '96', '7.00', '7.00'),
  day('DAYCOVAL GOVERNO ACRE TRANSFERENCIA TAB 1 DIG 120X', 'TRANSFERENCIA', ['2.30', '2.30'], '120', '6.50', '6.50'),
  day('DAYCOVAL GOV ACRE REFIN PORT TAB 1 LIQ DIG 84X', 'REFIN DA PORTABILIDADE', ['2.20', '2.20'], '84', '5.40', '5.40'),
  day('DAYCOVAL GOV ACRE PORTABILIDADE TABELAO 1 DIG 1 A 120X', 'PORTABILIDADE', ['1.43', '2.50'], '1 a 120', '0.00', '0.00'),
]

test('bevicred Daycoval table saved as xlsx: type from "Forma Contrato", Transferência is debt purchase, date is the day', () => {
  const r = bevicredGridRows(DAY)
  assert.ok(!('error' in r))
  assert.deepEqual(r.rows[1], ['GOV ACRE', 'DAYCOVAL GOV ACRE NOVO TAB 1 DIG', '760001', '2026-10-22', 'novo', '96', '96', '2.40', '7.00', ''])
  assert.deepEqual(r.rows[2].slice(0, 5), ['GOV ACRE', 'DAYCOVAL GOVERNO ACRE TRANSFERENCIA TAB 1 DIG', '760001', '2026-10-22', 'compra_de_divida'])
  assert.equal(r.rows[3][4], 'refin_portabilidade') // the form wins over "REFIN" in the name
  assert.deepEqual(r.rows[4].slice(4), ['portabilidade', '1', '120', '', '0.00', ''])
})

test('bevicred Daycoval table: the same file as an Excel CSV (Windows-1252, merged cells empty) is recognised and gives the same lines', async () => {
  const blank = (row: string[], keep: (c: string, i: number) => boolean) => row.map((c, i) => keep(c, i) ? c : '')
  const csv = [[DAY[0][0], ...DAY_TOP.slice(1).map(() => '')], blank(DAY_TOP, (c, i) => DAY_TOP[i - 1] !== c), blank(DAY_SUB, (c, i) => DAY_TOP[i] !== c), ...DAY.slice(3)]
    .map(r => r.join(';')).join('\n')
  const r = await readSmartFile(latin1(csv), 'tabela.csv') // Excel writes CSV in Windows-1252
  assert.equal(r.format, 'bevicred')
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.rows, (bevicredGridRows(DAY) as { rows: string[][] }).rows)
})

test('bevicred Daycoval table: an unknown form, a monthly deferred or a missing column refuses the file', () => {
  const err = (g: string[][]) => { const r = bevicredGridRows(g); return 'error' in r ? r.error : 'ok' }
  assert.equal(err([...DAY.slice(0, 3), day('DAYCOVAL GOV ACRE NOVO TAB 1 DIG 96X', 'CARTAO', ['2.40', '2.40'], '96', '7.00', '7.00')]), 'bevicred_contract_form')
  assert.equal(err([...DAY.slice(0, 3), day('DAYCOVAL GOV ACRE NOVO TAB 1 DIG 96X', 'NOVO', ['2.40', '2.40'], '96', '7.00', '7.00', '0.10')]), 'bevicred_monthly_deferred')
  assert.equal(err([...DAY.slice(0, 3), day('DAYCOVAL SIAPE NOVO TAB 1 DIG 96X', 'NOVO', ['2.40', '2.40'], '96', '7.00', '7.00')]), 'bevicred_unknown_agreement')
  assert.equal(err([...DAY.slice(0, 3), day('DAYCOVAL GOV ACRE NOVO TAB 1 DIG 96X', 'NOVO', ['2.40', '2.40'], '96', '7.50', '7.00')]), 'bevicred_total_mismatch')
  assert.equal(err([DAY[0], DAY_TOP.slice(0, 10), DAY_SUB.slice(0, 10), ...DAY.slice(3)]), 'bevicred_layout_changed')
})
