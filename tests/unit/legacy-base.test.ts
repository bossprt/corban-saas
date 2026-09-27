import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { buildLegacyRows, guessLegacyMapping, LEGACY_FIELDS, LEGACY_ISSUE_LABEL } from '../../src/lib/legacy/parse'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')

test('legacy columns: obvious names are pre-selected, each column once, unknown ones left for the person', () => {
  const m = guessLegacyMapping(['CPF', 'Nome do Cliente', 'Celular', 'Banco', 'Contrato', 'Data Contrato', 'Valor Bruto', 'Parcela', 'Prazo', 'Corretor', 'Situação', 'Coluna X'])
  assert.deepEqual(m, { cpf: 'CPF', full_name: 'Nome do Cliente', phone: 'Celular', bank_name: 'Banco', contract_number: 'Contrato', contract_on: 'Data Contrato',
    requested_amount: 'Valor Bruto', installment_amount: 'Parcela', term: 'Prazo', seller_name: 'Corretor', status_text: 'Situação' })
  assert.equal(Object.values(guessLegacyMapping(['Valor', 'Valor'])).length, 1)
})

test('legacy rows: money and dates converted, unreadable values kept as they came (the preview shows the issue), blank lines skipped', () => {
  const sheet = { headers: ['CPF', 'Nome', 'Data', 'Valor', 'Prazo'], headerRow: 1, body: [
    ['390.533.447-05', 'Cliente', '10/05/2025', '10.000,00', '96'],
    ['', '', '', '', ''],
    ['12345678909', 'Outro', '2025-13-40', 'abc', '12'],
  ] }
  const rows = buildLegacyRows(sheet, { cpf: 'CPF', full_name: 'Nome', contract_on: 'Data', requested_amount: 'Valor', term: 'Prazo' })
  assert.deepEqual(rows, [
    { row: 2, cpf: '390.533.447-05', full_name: 'Cliente', contract_on: '2025-05-10', requested_amount: '10000.00', term: '96' },
    { row: 4, cpf: '12345678909', full_name: 'Outro', contract_on: '2025-13-40', requested_amount: 'abc', term: '12' },
  ])
})

test('every database issue has a text; CPF is the only required column', () => {
  for (const c of ['invalid_cpf', 'full_name_required', 'invalid_value', 'invalid_date', 'after_cutoff', 'already_in_corban', 'duplicate_contract']) assert.ok(LEGACY_ISSUE_LABEL[c], c)
  assert.deepEqual(LEGACY_FIELDS.filter(f => f.required).map(f => f.key), ['cpf'])
  const m = read('supabase/migrations/20260927160750_legacy_base_v1.sql')
  for (const c of Object.keys(LEGACY_ISSUE_LABEL)) assert.match(m, new RegExp(`'${c}'`), c)
})

test('the legacy base stays out of the pipeline, commission and finance', () => {
  const m = read('supabase/migrations/20260927160750_legacy_base_v1.sql')
  assert.doesNotMatch(m, /insert into public\.(proposals_v2|payout_entries|commission_receipts|proposal_commission_calcs)/)
  assert.match(m, /revoke all on public\.organization_legacy_settings, public\.legacy_import_batches, public\.legacy_import_rows, public\.legacy_contracts from public, anon, authenticated/)
  // The screen never puts a CPF in a URL: batches and clients are addressed by id.
  assert.doesNotMatch(read('src/app/app/configuracao/base-antiga/[id]/page.tsx'), /href=\{`[^`]*cpf/)
})

test('the 2tech contract search export is recognized column by column', () => {
  const m = guessLegacyMapping(['ContratoId', 'NumeroProposta', 'NumeroContrato', 'DataContrato', 'NomeCliente', 'CpfCliente', 'Banco', 'Convenio', 'TipoContrato', 'Prazo',
    'ValorBruto', 'ValorLiquido', 'ValorParcela', 'NomeCorretor', 'StatusProposta', 'TelefoneCliente'])
  assert.deepEqual(m, { cpf: 'CpfCliente', full_name: 'NomeCliente', phone: 'TelefoneCliente', bank_name: 'Banco', agreement_name: 'Convenio', contract_type: 'TipoContrato',
    ade: 'NumeroProposta', contract_number: 'NumeroContrato', legacy_ref: 'ContratoId', contract_on: 'DataContrato', requested_amount: 'ValorBruto', released_amount: 'ValorLiquido',
    installment_amount: 'ValorParcela', term: 'Prazo', seller_name: 'NomeCorretor', status_text: 'StatusProposta' })
})

test('browser reader: spreadsheet cells become plain text without float noise, the title line is found', async () => {
  const { cellText, splitSheet } = await import('../../src/lib/legacy/browser-read')
  assert.equal(cellText(0.1 + 0.2), '0.3')
  assert.equal(cellText(10000), '10000')
  assert.equal(cellText(1234.5), '1234.5')
  assert.equal(cellText(new Date(2025, 4, 10)), '2025-05-10')
  assert.equal(cellText(null), '')
  const s = splitSheet([['Relatório'], ['', ''], ['CPF', 'Nome'], ['1', 'A']])
  assert.deepEqual(s, { headers: ['CPF', 'Nome'], body: [['1', 'A']], headerRow: 3 })
})
