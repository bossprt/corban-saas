import test from 'node:test'
import assert from 'node:assert/strict'
import { pdfItemsToRows, type PdfItem } from '../../src/lib/imports/smart-pdf'
import { RECEIPT_PDF_RULES } from '../../src/lib/receipts/pdf'
import { buildReceiptRows, mergeReportFiles, splitHeader } from '../../src/lib/receipts/parse'

// Layout of a bank commission report (Banco Valor, 28/10/2026): centred titles, names left-aligned starting before
// their title, numbers right-aligned past it, a "TOTAL" block right under the last line. Fictitious data.
const H: [string, number, number][] = [['CPF', 54, 66], ['Creditado', 102, 128], ['Codigo', 156, 175], ['Cliente', 254, 273], ['Vlr Bruto', 358, 381], ['Vlr Liquido', 413, 441], ['Tit.', 470, 478], ['% Com.', 505, 527], ['Comissao', 553, 580], ['Contrato', 611, 635], ['Aceite', 669, 686], ['Tp Contrato', 715, 747]]
const it = (str: string, x: number, x1: number, y: number): PdfItem => ({ str, x, y, w: x1 - x })
const line = (y: number, ade: string, amount: string): PdfItem[] => [
  it('00000000191', 43, 77, y), it('23/10/2026', 101, 129, y), it(ade, 157, 175, y), it('CLIENTE FICTICIO DE TESTE', 189, 303, y),
  it('1.534,22', 376, 397, y), it('-', 454, 456, y), it('6', 475, 478, y), it('4,00', 509, 520, y), it(amount, 578, 592, y),
  it(ade, 615, 634, y), it('23/10/2026', 664, 692, y), it('Novo', 726, 743, y),
]
const page = (rows: [string, string][]): PdfItem[] => [
  it('Relatorio de Comissionamento', 32, 200, 556), it('Periodo de: 01/10/2026', 32, 160, 542),
  ...H.map(([s, x, x1]) => it(s, x, x1, 456)),
  ...rows.flatMap(([ade, amount], i) => line(443 - 12 * i, ade, amount)),
  it('TOTAL PRODUTO', 245, 300, 443 - 12 * rows.length), it('16.199,71', 371, 397, 443 - 12 * rows.length), it('842,95', 574, 592, 443 - 12 * rows.length),
  it('TOTAL A RECEBER', 241, 310, 300), it('834,95', 571, 592, 300),
]

test('receipt PDF: each value lands in its column even when it does not touch the title; the TOTAL block is not a line', () => {
  const r = pdfItemsToRows([page([['520571', '61,37'], ['518819', '373,02']])], RECEIPT_PDF_RULES)
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.rows[0], H.map(h => h[0]))
  assert.equal(r.rows.length, 3)
  const col = (name: string) => r.rows.slice(1).map(row => row[r.rows[0].indexOf(name)])
  assert.deepEqual(col('Contrato'), ['520571', '518819'])
  assert.deepEqual(col('Comissao'), ['61,37', '373,02'])
  assert.deepEqual(col('Vlr Liquido'), ['-', '-'])
  assert.deepEqual(col('Tit.'), ['6', '6'])
  assert.deepEqual(col('Cliente'), ['CLIENTE FICTICIO DE TESTE', 'CLIENTE FICTICIO DE TESTE'])
})

test('receipt PDF: a line with more cells than titles, or a cell far from every title, refuses the file', () => {
  const extra = page([['520571', '61,37']]).concat([it('?', 760, 790, 443)])
  assert.equal(pdfItemsToRows([extra], RECEIPT_PDF_RULES).issues[0].code, 'pdf_ambiguous_layout')
  const far = page([]).concat([it('520571', 157, 175, 443), it('61,37', 900, 920, 443)])
  assert.equal(pdfItemsToRows([far], RECEIPT_PDF_RULES).issues[0].code, 'pdf_ambiguous_layout')
})

test('receipt PDF: the commercial import keeps its own header (a receipt report is not a commission table)', () => {
  assert.equal(pdfItemsToRows([page([['520571', '61,37'], ['518819', '373,02']])]).issues[0].code, 'pdf_no_table')
})

test('upfront + bonus files: amounts of the same contract are added in cents; zero lines add nothing', () => {
  const headers = ['Contrato', 'Comissao']
  const body = [['A1', '373,02'], ['A2', '61,37'], ['A1', '435,19'], ['A2', '0,00'], ['A3', '0,00'], ['A4', '0,10'], ['A4', '0,20']]
  const fileOf = [0, 0, 1, 1, 1, 1, 1]
  const merged = mergeReportFiles(body, fileOf, 0, 1)
  assert.deepEqual(merged, [['A1', '808,21'], ['A2', '61,37'], ['A4', '0,10'], ['A4', '0,20']]) // same file: never added
  const built = buildReceiptRows({ headers, body: merged, headerRow: 1 }, { ade: 'Contrato', amount: 'Comissao' }, 'upfront')
  assert.deepEqual(built.issues, [])
  assert.deepEqual(built.rows.map(r => [r.ade, r.amount]), [['A1', '808.21'], ['A2', '61.37'], ['A4', '0.10'], ['A4', '0.20']])
  assert.equal(mergeReportFiles([['A1', '0,10'], ['A1', '0,20']], [0, 1], 0, 1)[0][1], '0,30') // 0.1 + 0.2, exact
})

test('a single report with zero lines imports the paid lines and skips the zeros', () => {
  const sheet = splitHeader([['Contrato', 'Comissao'], ['A1', '435,19'], ['A2', '0,00'], ['A3', 'R$ 0']])!
  const built = buildReceiptRows(sheet, { ade: 'Contrato', amount: 'Comissao' }, 'upfront')
  assert.deepEqual(built.issues, [])
  assert.deepEqual(built.rows.map(r => r.ade), ['A1'])
  assert.equal(built.skipped, 2)
})
