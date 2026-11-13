import test from 'node:test'
import assert from 'node:assert/strict'
import type { PdfItem } from '../../src/lib/imports/smart-pdf'
import { suggestAgreementId, valorPdfSheet } from '../../src/lib/imports/valor-pdf'
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
  assert.deepEqual(sheet.products.map(p => p.label), ['CONSIG. EMPRESTIMO RIO BRANCO I'])
  assert.deepEqual(sheet.productOfRow, [0, 0])
  const parsed = parseContractSheet(sheet.rows, '2026-11-03', valor)
  assert.deepEqual(parsed.map.issues, [])
  assert.deepEqual(parsed.map.ignored, ['% Com.', 'Comissao', 'Contrato', 'Aceite'])
  assert.deepEqual(parsed.lines.map(l => [l.ade, l.term, l.requested, l.released, l.typeKey, l.stage, l.paidOn, l.table, l.issues]), [
    ['520571', 6, '1534.22', null, 'novo', 'paid', '2026-10-23', '', []],
    ['520997', 24, '9085.85', null, 'novo', 'paid', '2026-10-23', '', []],
  ])
  assert.equal(parsed.lines[0].name, 'CLIENTE FICTICIO DE TESTE')
})

// Several product blocks on a page (13/11/2026 reports): product line, titles, contracts, TOTAL; a block that starts at
// the bottom of a page continues on the next one, and the page number never sticks to a cell.
const blockPage = (blocks: [string, [string, string, string][]][], pageNo: number): PdfItem[] => {
  const out: PdfItem[] = [it('Relatorio de Comissionamento por Correspondente', 32, 260, 556)]
  let y = 500
  for (const [product, rows] of blocks) {
    out.push(it(product, 32, 200, y), ...H.map(([s, x, x1]) => it(s, x, x1, y - 14)))
    rows.forEach(([ade, term, amount], i) => out.push(...line(y - 27 - 12 * i, ade, term, amount)))
    if (rows.length) out.push(it('TOTAL PRODUTO', 245, 300, y - 27 - 12 * rows.length))
    y -= 60 + 12 * rows.length
  }
  out.push(it(`Pag.: ${pageNo}`, 560, 590, 11))
  return out
}

test('Valor PDF: several products in one report, each contract keeps its block; a block continues on the next page', () => {
  const sheet = valorPdfSheet([
    blockPage([['CONSIG. EMPRESTIMO RORAIMA II', [['100001', '96', '1.000,00'], ['100002', '24', '2.000,00']]], ['CONSIG. CARTAO BENEFICIO SAQUE GOV. SP', []]], 1),
    blockPage([['CONSIG. CARTAO BENEFICIO SAQUE GOV. SP', [['100003', '96', '3.000,00']]]], 2),
  ])
  assert.ok(!('error' in sheet), JSON.stringify(sheet))
  assert.deepEqual(sheet.products.map(p => p.label), ['CONSIG. EMPRESTIMO RORAIMA II', 'CONSIG. CARTAO BENEFICIO SAQUE GOV. SP'])
  assert.deepEqual(sheet.productOfRow, [0, 0, 1])
  const tp = sheet.rows[0].indexOf('Tp Contrato')
  assert.deepEqual(sheet.rows.slice(1).map(r => r[tp]), ['NOVO', 'NOVO', 'NOVO'])
})

test('Valor PDF: the product only suggests an agreement, and only when exactly one matches', () => {
  const ag = [{ id: 'r', name: 'Governo de Roraima' }, { id: 'sp', name: 'Governo de São Paulo' }, { id: 'psp', name: 'Prefeitura de São Paulo' }, { id: 'dc', name: 'Pref D Caxias' }]
  const sheet = valorPdfSheet([blockPage([['CONSIG. EMPRESTIMO RORAIMA II', [['1', '6', '1,00']]], ['CONSIG. CARTAO BENEFICIO SAQUE GOV. SP', [['2', '6', '1,00']]],
    ['CONSIG. CARTAO BENEFICIO SAQUE FLEX PREF. DQ.', [['3', '6', '1,00']]], ['CONSIG CARTÃO MANAUSPREV - COM PREV', [['4', '6', '1,00']]]], 1)])
  assert.ok(!('error' in sheet), JSON.stringify(sheet))
  assert.deepEqual(sheet.products.map(p => suggestAgreementId(p.hint, ag)), ['r', 'sp', 'dc', null])
  assert.equal(suggestAgreementId(sheet.products[0].hint, [...ag, { id: 'r2', name: 'Gov Roraima' }]), null)
})

test('Valor PDF: no product line refuses the file instead of guessing', () => {
  const none = valorPdfSheet([page([], [['520571', '6', '1.534,22']])])
  assert.ok('error' in none && /Não encontrei o produto/.test(none.error))
})

test('Valor PDF: the spreadsheet layouts still require the Tabela column', () => {
  const nasp = CONTRACT_LAYOUTS.find(l => l.key === 'nasp')!
  const parsed = parseContractSheet([['CPF', 'Prazo', 'Valor liberado'], ['00000000191', '6', '100,00']], '2026-11-03', nasp)
  assert.ok(parsed.map.issues.some(i => i.code === 'missing_column' && i.column === 'Tabela'))
})
