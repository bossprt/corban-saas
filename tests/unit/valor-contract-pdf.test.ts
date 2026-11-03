import test from 'node:test'
import assert from 'node:assert/strict'
import type { PdfItem } from '../../src/lib/imports/smart-pdf'
import { valorPdfSheet } from '../../src/lib/imports/valor-pdf'
import { CONTRACT_LAYOUTS, parseContractSheet } from '../../src/lib/imports/contract-layout'

// Banco Valor commission report as contracts (owner request 03/11/2026): the geometry of the bank's PDF, product line
// above the titles, "TOTAL" block under the last line. Fictitious data.
const H: [string, number, number][] = [['CPF', 54, 66], ['Creditado', 102, 128], ['Codigo', 156, 175], ['Cliente', 254, 273], ['Vlr Bruto', 358, 381], ['Vlr Liquido', 413, 441], ['Tit.', 470, 478], ['% Com.', 505, 527], ['Comissao', 553, 580], ['Contrato', 611, 635], ['Aceite', 669, 686], ['Tp Contrato', 715, 747]]
const it = (str: string, x: number, x1: number, y: number): PdfItem => ({ str, x, y, w: x1 - x })
const line = (y: number, ade: string, term: string, amount: string): PdfItem[] => [
  it('00000000191', 43, 77, y), it('23/10/2026', 101, 129, y), it(ade, 157, 175, y), it('CLIENTE FICTICIO DE TESTE', 189, 303, y),
  it(amount, 376, 397, y), it('-', 454, 456, y), it(term, 475, 478, y), it('4,00', 509, 520, y), it('61,37', 578, 592, y),
  it(ade, 615, 634, y), it('23/10/2026', 664, 692, y), it('NOVO', 726, 743, y),
]
const page = (product: string[], rows: [string, string, string][]): PdfItem[] => [
  it('Relatorio de Comissionamento por Correspondente', 32, 260, 556), it('Periodo de: 22/10/2026 Ate: 30/10/2026', 32, 200, 542),
  ...product.map((p, i) => it(p, 32, 200, 470 - 4 * i)),
  ...H.map(([s, x, x1]) => it(s, x, x1, 456)),
  ...rows.flatMap(([ade, term, amount], i) => line(443 - 12 * i, ade, term, amount)),
  it('TOTAL PRODUTO', 245, 300, 443 - 12 * rows.length), it('19.151,14', 371, 397, 443 - 12 * rows.length),
  it('TOTAL A PAGAR', 241, 310, 300), it('1.010,38', 571, 592, 300),
]
const valor = CONTRACT_LAYOUTS.find(l => l.key === 'valor')!

test('Valor PDF: each line becomes a paid contract with ADE, term, gross amount, type and credit date; no table needed', () => {
  const sheet = valorPdfSheet([page(['CONSIG. EMPRESTIMO RIO BRANCO I'], [['520571', '6', '1.534,22'], ['520997', '24', '9.085,85']])])
  assert.ok(!('error' in sheet))
  assert.equal(sheet.product.agreement, 'Prefeitura de Rio Branco')
  assert.equal(sheet.product.tablePrefix, 'emprestimo')
  const parsed = parseContractSheet(sheet.rows, '2026-11-03', valor)
  assert.deepEqual(parsed.map.issues, [])
  assert.deepEqual(parsed.map.ignored, ['% Com.', 'Comissao', 'Contrato', 'Aceite'])
  assert.deepEqual(parsed.lines.map(l => [l.ade, l.term, l.requested, l.released, l.typeKey, l.stage, l.paidOn, l.table, l.issues]), [
    ['520571', 6, '1534.22', null, 'novo', 'paid', '2026-10-23', '', []],
    ['520997', 24, '9085.85', null, 'novo', 'paid', '2026-10-23', '', []],
  ])
  assert.equal(parsed.lines[0].name, 'CLIENTE FICTICIO DE TESTE')
})

test('Valor PDF: a product without layout, a missing product or two products refuse the file instead of guessing', () => {
  const rows: [string, string, string][] = [['520571', '6', '1.534,22']]
  const unknown = valorPdfSheet([page(['CONSIG. EMPRESTIMO GOVERNO DO ACRE'], rows)])
  assert.ok('error' in unknown && /ainda não tem layout/.test(unknown.error))
  const none = valorPdfSheet([page([], rows)])
  assert.ok('error' in none && /Não encontrei o produto/.test(none.error))
  const two = valorPdfSheet([page(['CONSIG. EMPRESTIMO RIO BRANCO I'], rows), page(['CONSIG. CARTAO RIO BRANCO'], rows)])
  assert.ok('error' in two && /mais de um produto/.test(two.error))
})

test('Valor PDF: the spreadsheet layouts still require the Tabela column', () => {
  const nasp = CONTRACT_LAYOUTS.find(l => l.key === 'nasp')!
  const parsed = parseContractSheet([['CPF', 'Prazo', 'Valor liberado'], ['00000000191', '6', '100,00']], '2026-11-03', nasp)
  assert.ok(parsed.map.issues.some(i => i.code === 'missing_column' && i.column === 'Tabela'))
})
