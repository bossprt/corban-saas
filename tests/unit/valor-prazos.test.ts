import test from 'node:test'
import assert from 'node:assert/strict'
import type { PdfItem } from '../../src/lib/imports/smart-pdf'
import { isValorPrazos, pctText, suggestAgreement, valorPrazosProducts, valorPrazosRows } from '../../src/lib/imports/valor-prazos'
import { mapSmartCommercialRows } from '../../src/lib/imports/smart-commercial'

// Banco Valor "Prazos e Comissões" PDF (owner request 13/11/2026), geometry of the October edition: text at x=48, the
// "Parcelas | Comissão" header and the bands at x=54 / x=524, footer on every page.
const it = (str: string, x: number, y: number): PdfItem => ({ str, x, y, w: str.length * 4 })
type Block = { text: string[]; bands: [string, string][] }
function page(blocks: Block[], first: boolean, n = 1): PdfItem[] {
  const out: PdfItem[] = []
  let y = 770
  if (first) { out.push(it('Prazos e Comissões 2026', 177, y), it('Valor Financiamentos · Atualizado em Outubro', 48, y - 19), it('Consulte quanto de comissão cada produto paga.', 48, y - 34)); y -= 64 }
  for (const b of blocks) {
    for (const t of b.text) { out.push(it(t, 48, y)); y -= 11 }
    out.push(it('Parcelas', 54, y), it('Comissão', 499, y)); y -= 20
    for (const [l, p] of b.bands) { out.push(it(l, 54, y), it(p, 524, y)); y -= 20 }
    y -= 12
  }
  out.push(it('Prazos e Comissões 2026 — Valor Financiamentos · Documento somente leitura, não editável', 48, 34), it(`Página ${n} de 2`, 500, 34))
  return out
}
const PUB_I: Block = { text: ['Consig. Pub I — Empréstimo', 'Empréstimo consignado', 'Comissionados / Temporários / CLT'], bands: [['6x – 12x', '6%'], ['13x – 23x', '10%'], ['24x – 35x', '15%']] }
const GOIAS: Block = { text: ['Cartão Benefício Saque/Compra Goiás', 'Benefício Saque/Compra', 'Efetivos', 'Obs.: Condições Efetivo I–IV'], bands: [['Efetivo I · 36x', '6%'], ['Efetivo IV · 36x', '30%']] }
const SIAPE: Block = { text: ['SIAPE', 'Benefício', 'Efetivos'], bands: [['36x', '10%'], ['96x', '30%']] }

test('Valor prazos: recognised by its title, products split into upfront 6% + bonus, Goiás levels become tables', () => {
  const pages = [page([PUB_I, GOIAS], true), page([SIAPE], false, 2)]
  assert.equal(isValorPrazos(pages), true)
  const r = valorPrazosProducts(pages)
  assert.ok(!('error' in r))
  assert.deepEqual(r.products.map(p => [p.table, p.hint, p.bands.map(b => [b.min, b.max, b.total, b.upfront, b.bonus])]), [
    ['Consig. Pub I — Empréstimo', null, [[6, 12, '6', '6', '0'], [13, 23, '10', '6', '4'], [24, 35, '15', '6', '9']]],
    ['Cartão Benefício Saque/Compra Goiás – Efetivo I', 'goias', [[36, 36, '6', '6', '0']]],
    ['Cartão Benefício Saque/Compra Goiás – Efetivo IV', 'goias', [[36, 36, '30', '6', '24']]],
    ['SIAPE', 'siape', [[36, 36, '10', '6', '4'], [96, 96, '30', '6', '24']]],
  ])
})

test('Valor prazos: a band below 6% is all upfront; decimals use integer hundredths', () => {
  const r = valorPrazosProducts([page([{ ...SIAPE, bands: [['12x', '4,5%'], ['24x', '6,25%']] }], true)])
  assert.ok(!('error' in r))
  assert.deepEqual(r.products[0].bands.map(b => [b.total, b.upfront, b.bonus]), [['4,5', '4,5', '0'], ['6,25', '6', '0,25']])
  assert.equal(pctText(1005), '10,05')
})

test('Valor prazos: anything outside the layout refuses the file (never guessed)', () => {
  const bad = (b: Block) => valorPrazosProducts([page([b], true)])
  assert.equal((bad({ ...SIAPE, bands: [['36 meses', '10%']] }) as { error: string }).error, 'valor_prazos_layout')
  assert.equal((bad({ ...SIAPE, bands: [['36x', 'dez%']] }) as { error: string }).error, 'valor_prazos_layout')
  assert.equal((bad({ ...SIAPE, bands: [['12x – 36x', '10%'], ['24x', '12%']] }) as { error: string }).error, 'valor_prazos_layout')
  assert.equal((bad({ ...SIAPE, bands: [['36x', '120%']] }) as { error: string }).error, 'valor_prazos_layout')
  assert.equal(isValorPrazos([[it('Relatorio de Comissionamento', 32, 556)]]), false)
})

test('Valor prazos: agreement suggested only when exactly one active agreement matches', () => {
  const ag = [{ id: 'a', name: 'Governo de São Paulo' }, { id: 'b', name: 'Prefeitura de São Paulo' }, { id: 'c', name: 'Pref D Caxias' }, { id: 'd', name: 'Siape' }, { id: 'e', name: 'Governo de Goiás' }]
  assert.equal(suggestAgreement('gov_sp', ag)?.id, 'a')
  assert.equal(suggestAgreement('caxias', ag)?.id, 'c')
  assert.equal(suggestAgreement('siape', ag)?.id, 'd')
  assert.equal(suggestAgreement('goias', ag)?.id, 'e')
  assert.equal(suggestAgreement('goias', [...ag, { id: 'f', name: 'Gov Goiás' }]), null)
  assert.equal(suggestAgreement(null, ag), null)
})

test('Valor prazos rows feed the commercial import: Novo, one condition per term, upfront and bonus components', () => {
  const r = valorPrazosProducts([page([PUB_I], true)])
  assert.ok(!('error' in r))
  const rows = valorPrazosRows(r.products, 'Valor Financiamento', () => 'Governo do Amazonas')
  const mapped = mapSmartCommercialRows(rows, {
    contractTypes: [{ id: 'novo-id', name: 'Novo', tech_key: 'novo' }], groups: [],
    components: [{ id: 'up', tech_key: 'upfront', name: 'À vista' }, { id: 'bo', tech_key: 'bonus_1', name: 'Bônus' }], defaultBase: 'BRUTO',
  })
  assert.deepEqual(mapped.issues, [])
  assert.equal(mapped.rows.length, 30) // 7 + 11 + 12 terms
  const at = (t: number) => mapped.rows.find(x => x.term === t)!
  assert.deepEqual(at(12).components.map(c => [c.component_type_id, c.received_value]), [['up', '6']])
  assert.deepEqual(at(30).components.map(c => [c.component_type_id, c.received_value]), [['up', '6'], ['bo', '9']])
  assert.equal(at(30).agreement_name, 'Governo do Amazonas')
  assert.equal(at(30).contract_type_name, 'Novo')
  assert.equal(at(30).rate, null)
})
