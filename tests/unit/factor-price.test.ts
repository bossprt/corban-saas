import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { parseFactorPrice } from '../../src/lib/imports/factor-price'

const row = (cells: Record<number, string>) => Array.from({ length: 12 }, (_, i) => cells[i] ?? '')
const sheet = (code: string, tc = '0,00', grid: string[][] = [row({ 1: '08/10/2026', 3: '05/12/2026', 4: '0,00', 5: '0,03795', 11: '0,02782' })]) => [
  row({ 17: 'MPPRICECVA (DCE-EFETIVAMAIS1008)' }),
  row({ 1: 'Fatores Price', 10: 'OBS:' }),
  row({ 1: 'Empregador:', 3: 'GOV ACRE' }),
  row({ 1: 'Conv�nio:', 3: `${code}  GOVACRE1DIGAOL` }),
  row({ 1: 'TC:', 3: tc }),
  row({ 1: 'Data Base', 3: '1� Venc', 4: 'Tx Cet', 5: '48 meses', 11: '120 meses' }),
  ...grid,
]

test('fator price: code and label from Convênio, one line per date, factors as exact strings', () => {
  const r = parseFactorPrice([{ name: 'Sheet1', rows: sheet('761111', '0,00', [
    row({ 1: '08/10/2026', 5: '0,03795', 11: '0,02782' }), row({ 1: '09/10/2026', 11: '0,02779' })]) }])
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.sheets, [{ code: '761111', label: 'GOVACRE1DIGAOL', employer: 'GOV ACRE', dates: [
    { date: '2026-10-08', entries: [{ term: 48, factor: '0.03795' }, { term: 120, factor: '0.02782' }] },
    { date: '2026-10-09', entries: [{ term: 120, factor: '0.02779' }] }] }])
})
test('fator price: a TC other than zero, a bad factor and the same table twice with different factors are reported', () => {
  const r = parseFactorPrice([
    { name: 'A', rows: sheet('745031', '15,00') },
    { name: 'B', rows: sheet('745032', '0,00', [row({ 1: '08/10/2026', 11: 'abc' }), row({ 1: '09/10/2026', 11: '0,02' })]) },
    { name: 'C', rows: sheet('745033') }, { name: 'D', rows: sheet('745033', '0,00', [row({ 1: '08/10/2026', 11: '0,02999' })]) },
    { name: 'E', rows: [row({}), row({ 1: 'nada' })] },
  ])
  assert.deepEqual(r.sheets.map(s => s.code), ['745032', '745033'])
  assert.equal(r.issues.length, 3)
  assert.match(r.issues[0].message, /TC 15,00/)
  assert.match(r.issues[1].message, /Fator inválido/)
  assert.match(r.issues[2].message, /duas vezes/)
})
test('fator price: merged cells repeat values (label, header, terms) and are read once', () => {
  const r = parseFactorPrice([{ name: 'M', rows: [
    ['', 'Convênio:', 'Convênio:', '761111  GOVACRE1DIGAOL', '761111  GOVACRE1DIGAOL'],
    ['', 'TC:', 'TC:', '0,00', '0,00'],
    ['', 'Data Base', 'Data Base', '1º Venc', 'Tx Cet', '48 meses', '60 meses', '60 meses', '120 meses'],
    ['', '08/10/2026', '08/10/2026', '05/12/2026', '0,00', '0,03795', '0,03412', '0,03412', '0,02782'],
  ] }])
  assert.deepEqual(r.issues, [])
  assert.equal(r.sheets[0].code, '761111')
  assert.deepEqual(r.sheets[0].dates[0].entries.map(e => e.term), [48, 60, 120])
})
test('fator price: a number cell (0.02816) is read as is', () => {
  const r = parseFactorPrice([{ name: 'S', rows: sheet('745031', '0', [row({ 1: '08/10/2026', 11: '0.02816' })]) }])
  assert.equal(r.sheets[0].dates[0].entries[0].factor, '0.02816')
})
test('factor price import: governed RPC, manager only, no float', () => {
  const m = readFileSync('supabase/migrations/20261008141157_factor_price_import_v1.sql', 'utf8')
  assert.match(m, /has_active_organization_role\(p_org, array\['admin','manager'\]\)/)
  assert.doesNotMatch(m, /security definer|float|double precision/i)
})
