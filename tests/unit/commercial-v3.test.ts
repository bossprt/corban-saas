import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { IMPORT_ISSUE_TEXT, IMPORT_MAX_ROWS, effectiveOf, fromScaled, mapConditionRows, netBase, normalizeHeader, parseCoefficient, parseDecimal, parseDelimited, parsePercent, parseRate, parseTerm, resolveShares, scaled, validateShares, type GroupRef, type PolicyRef } from '../../src/lib/commercial'
import { FEEDBACK, isFeedbackCode } from '../../src/lib/feedback'
import { setupItems, STANDARD_STAGES } from '../../src/lib/catalog'
import { TENANT_FREE_TABLES } from '../../src/lib/tenant'
import { atLeast, canViewCommission } from '../../src/lib/rbac'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const code = (src: string) => src.split('\n').filter(l => !l.trim().startsWith('--') && !l.trim().startsWith('//')).join('\n')

const G: GroupRef[] = [
  { id: 'g-corretor', name: 'Corretor', basis: 'percent_of_production' },
  { id: 'g-parceiro', name: 'Parceiro', basis: 'percent_of_received_commission' },
  { id: 'g-gerente', name: 'Gerente', basis: 'percent_of_production' },
]
const T = [{ id: 't-novo', name: 'Novo', tech_key: 'novo' }, { id: 't-compra', name: 'Compra de Dívida', tech_key: 'compra_de_divida' }, { id: 't-port', name: 'Portabilidade', tech_key: 'portabilidade' }]

// ---- numbers: never a float
test('decimals are canonical strings: comma, percent sign and leading zeros are normalised; everything ambiguous is refused', () => {
  assert.equal(parseDecimal('1,85', { maxInt: 3, scale: 6 }), '1.85')
  assert.equal(parseDecimal(' 7% ', { maxInt: 3, scale: 6 }), '7')
  assert.equal(parseDecimal('007.50', { maxInt: 3, scale: 6 }), '7.50')
  assert.equal(parseCoefficient('0,01234567'), '0.01234567')
  for (const bad of ['1e3', '-1', '1.2.3', '1.234,5', 'abc', '0.1234567', '1000']) assert.equal(parsePercent(bad), null, bad)
  assert.equal(parseCoefficient('0.123456789'), null) // 9 decimals do not fit numeric(14,8)
  assert.equal(parseRate('1000'), null)
})
test('percentages are compared exactly (BigInt scaled), not with floating point', () => {
  assert.notEqual(0.1 + 0.2, 0.3) // the trap this design avoids
  assert.equal(scaled('0.1') + scaled('0.2'), scaled('0.3'))
  assert.equal(scaled('45.5'), BigInt(45500000))
  assert.equal(scaled('100'), BigInt(100000000))
})
test('term is an integer 1..600', () => {
  for (const [v, want] of [['84', 84], ['1', 1], ['600', 600], ['0', null], ['601', null], ['12.5', null], ['-3', null], ['abc', null], ['', null]] as const) assert.equal(parseTerm(v), want, v)
})

// ---- share semantics: groups are ALTERNATIVE sellers (mirror of save_commercial_condition); the cap is per group, never a sum
const R: GroupRef[] = [...G, { id: 'g-balcao', name: 'Balcão', basis: 'percent_of_received_commission' }, { id: 'g-indicador', name: 'Indicador', basis: 'percent_of_received_commission' }]
test('shares: each group is capped on its own (production % <= commission received; received % <= 100); nothing is summed across groups', () => {
  assert.equal(validateShares(G, [{ group_id: 'g-corretor', pct: '4' }, { group_id: 'g-parceiro', pct: '45.5' }, { group_id: 'g-gerente', pct: '0.2' }], '7'), null)
  // the V3 document row pays 4 + 3.5 + 1 + 2 + 0.3 + 0.2 = 11% against 7% received: legitimate, they are alternatives
  assert.equal(validateShares(G, [{ group_id: 'g-corretor', pct: '4' }, { group_id: 'g-gerente', pct: '3.5' }], '7'), null)
  assert.equal(validateShares(G, [{ group_id: 'g-corretor', pct: '7' }], '7'), null) // exactly the commission received is fine
  assert.equal(validateShares(G, [{ group_id: 'g-corretor', pct: '7.000001' }], '7'), 'production_shares_exceed_received_commission')
  assert.equal(validateShares(G, [{ group_id: 'g-parceiro', pct: '100' }], '0'), null)
  assert.equal(validateShares(G, [{ group_id: 'g-parceiro', pct: '101' }], '7'), 'invalid_shares')
  assert.equal(validateShares(G, [{ group_id: 'g-parceiro', pct: '60' }, { group_id: 'g-parceiro', pct: '10' }], '7'), 'duplicate_group_share')
  assert.equal(validateShares(G, [{ group_id: 'nope', pct: '1' }], '7'), 'commission_group_not_found')
  assert.equal(validateShares(G, [{ group_id: 'g-corretor', pct: 'x' }], '7'), 'invalid_shares')
  assert.equal(validateShares(G, [], '7'), null)
})
test('payout policy: group commission = base x percentage of the RECEIVED commission (Owner example: 10% received)', () => {
  const policy: PolicyRef = { baseKind: 'gross', discountPct: '0', items: [{ group_id: 'g-balcao', pct: '50' }, { group_id: 'g-indicador', pct: '25' }, { group_id: 'g-parceiro', pct: '80' }] }
  const r = resolveShares(R, [], '10', policy)
  assert.equal(r.error, null)
  const eff = Object.fromEntries(r.rows.map(x => [x.group_id, x.effective]))
  assert.deepEqual(eff, { 'g-balcao': '5', 'g-indicador': '2.5', 'g-parceiro': '8' })
  assert.ok(r.rows.every(x => x.source === 'policy'))
  // 65% Corretor is 6.5% of the production when the company received 10% (Corretor read on the received commission)
  const corretorRc: GroupRef[] = [{ id: 'c', name: 'Corretor RC', basis: 'percent_of_received_commission' }]
  assert.equal(resolveShares(corretorRc, [{ group_id: 'c', pct: '65' }], '10').rows[0].effective, '6.5')
})
test('payout policy: net base applies the tax/discount first (10% received, 10% tax -> 9% base; 65% of it = 5.85%); gross and net are never mixed', () => {
  assert.equal(fromScaled(netBase('10', { baseKind: 'net', discountPct: '10' })), '9')
  assert.equal(fromScaled(netBase('10', { baseKind: 'gross', discountPct: '10' })), '10') // a gross policy ignores any discount
  const net: PolicyRef = { baseKind: 'net', discountPct: '10', items: [{ group_id: 'g-parceiro', pct: '80' }] }
  assert.equal(resolveShares(R, [], '10', net).rows[0].effective, '7.2')
  const c: GroupRef[] = [{ id: 'c', name: 'C', basis: 'percent_of_received_commission' }]
  assert.equal(resolveShares(c, [], '10', { baseKind: 'net', discountPct: '10', items: [{ group_id: 'c', pct: '65' }] }).rows[0].effective, '5.85')
})
test('payout policy: rounding is half-up at 6 places, identical to round(numeric, 6) in the database; sums are exact', () => {
  assert.equal(fromScaled(effectiveOf(scaled('7'), '45.5')), '3.185')
  assert.equal(fromScaled(effectiveOf(scaled('0.000001'), '50')), '0.000001') // 0.0000005 rounds half up
  assert.equal(fromScaled(effectiveOf(scaled('0.000001'), '49.9')), '0')
  assert.equal(fromScaled(scaled('12.345678')), '12.345678')
  assert.equal(fromScaled(scaled('7.500000')), '7.5')
})
test('payout policy: an explicit value overrides the policy for that group only (traceable), a production group stays manual, an inactive policy group is refused', () => {
  const policy: PolicyRef = { baseKind: 'gross', discountPct: '0', items: [{ group_id: 'g-parceiro', pct: '80' }, { group_id: 'g-balcao', pct: '50' }] }
  const r = resolveShares(R, [{ group_id: 'g-parceiro', pct: '70' }, { group_id: 'g-corretor', pct: '4' }], '10', policy)
  assert.equal(r.error, null)
  const by = Object.fromEntries(r.rows.map(x => [x.group_id, x]))
  assert.deepEqual([by['g-parceiro'].source, by['g-parceiro'].effective], ['override', '7'])
  assert.deepEqual([by['g-corretor'].source, by['g-corretor'].effective], ['manual', '4'])
  assert.deepEqual([by['g-balcao'].source, by['g-balcao'].effective], ['policy', '5'])
  const inactive = R.filter(g => g.id !== 'g-balcao')
  assert.equal(resolveShares(inactive, [], '10', policy).error, 'policy_group_inactive')
})

// ---- CSV
test('CSV reader: BOM, CRLF, semicolon or comma, quoted fields with delimiter and escaped quotes', () => {
  assert.deepEqual(parseDelimited('﻿a;b;c\r\n1;"x;y";3\r\n'), [['a', 'b', 'c'], ['1', 'x;y', '3']])
  assert.deepEqual(parseDelimited('a,b\n"he said ""hi""",2\n\n'), [['a', 'b'], ['he said "hi"', '2']])
  assert.deepEqual(parseDelimited('a\tb\n1\t2'), [['a', 'b'], ['1', '2']])
})
test('header normalisation ignores case, accents and punctuation', () => {
  assert.equal(normalizeHeader(' Comissão Recebida (%) '), 'comissao_recebida')
  assert.equal(normalizeHeader('Tipo de Contrato'), 'tipo_de_contrato')
})

// ---- import with ONE COLUMN PER COMMISSION GROUP
const ctx = { groups: G, contractTypes: T }
const HEAD = ['Tipo de Contrato', 'Prazo', 'Coeficiente', 'Taxa', 'Comissão recebida', 'Corretor', 'Parceiro', 'Gerente']
test('import: one row carries the received commission and every group at once (the V3 document example)', () => {
  const r = mapConditionRows([HEAD, ['Novo', '84', '0,01234567', '1,85', '7', '4', '45,5', '0,2'], ['Portabilidade', '96', '', '1,5', '5', '', '', '']], ctx)
  assert.deepEqual(r.issues, [])
  assert.equal(r.conditions.length, 2)
  const { resolved, ...first } = r.conditions[0]
  assert.deepEqual(first, { line: 2, contractTypeId: 't-novo', term: 84, coefficient: '0.01234567', rate: '1.85', received: '7', shares: [{ group_id: 'g-corretor', pct: '4' }, { group_id: 'g-parceiro', pct: '45.5' }, { group_id: 'g-gerente', pct: '0.2' }] })
  assert.deepEqual(resolved.map(x => [x.group_id, x.effective]), [['g-corretor', '4'], ['g-parceiro', '3.185'], ['g-gerente', '0.2']]) // 7% x 45.5% = 3.185%
  assert.deepEqual(r.conditions[1].shares, []) // blank group cell = not part of the condition, NOT zero
  assert.equal(r.conditions[1].coefficient, null)
})
test('import: group columns are dynamic (any tenant group name, any count, any order, "Grupo X" prefix allowed)', () => {
  const groups: GroupRef[] = [{ id: 'a', name: 'Equipe Sul', basis: 'percent_of_production' }, { id: 'b', name: 'Indicação', basis: 'percent_of_received_commission' }]
  const r = mapConditionRows([['prazo', 'contrato', 'coeficiente', 'comissao', 'grupo_indicacao', 'EQUIPE SUL'], ['12', 'novo', '0.05', '6', '10', '2']], { groups, contractTypes: T })
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.conditions[0].shares, [{ group_id: 'b', pct: '10' }, { group_id: 'a', pct: '2' }])
})
test('import: an unknown column is REFUSED, never silently ignored (a typo would drop a group commission)', () => {
  const r = mapConditionRows([[...HEAD.slice(0, 7), 'Gerent'], ['Novo', '84', '0.01', '', '7', '4', '', '1']], ctx)
  assert.equal(r.conditions.length, 0)
  assert.ok(r.issues.some(i => i.code === 'unknown_column' && i.detail === 'Gerent'))
})
test('import: missing/duplicated columns, bad rows and duplicate keys are all reported with their line', () => {
  assert.ok(mapConditionRows([['Prazo', 'Coeficiente', 'Comissão recebida'], ['12', '0.1', '5']], ctx).issues.some(i => i.code === 'missing_column_contract'))
  assert.ok(mapConditionRows([['Tipo de Contrato', 'Prazo', 'Comissão recebida'], ['Novo', '12', '5']], ctx).issues.some(i => i.code === 'missing_column_coefficient_or_rate'))
  assert.ok(mapConditionRows([['Tipo de Contrato', 'Prazo', 'Prazo', 'Coeficiente', 'Comissão recebida'], ['Novo', '12', '12', '0.1', '5']], ctx).issues.some(i => i.code === 'duplicate_column'))
  const bad = mapConditionRows([HEAD, ['Inexistente', '84', '0.01', '', '7', '', '', ''], ['Novo', '0', '0.01', '', '7', '', '', ''], ['Novo', '84', '', '', '7', '', '', ''], ['Novo', '84', '0.01', '', '', '', '', ''], ['Novo', '84', '0.01', '', '7', '8', '', ''], ['Novo', '48', '0.01', '', '7', '', '150', ''], ['Novo', '60', '0.01', '', '7', '', '', ''], ['Novo', '60', '0.02', '', '7', '', '', '']], ctx)
  assert.equal(bad.conditions.length, 0) // one bad line refuses the whole file
  assert.deepEqual(bad.issues.map(i => [i.line, i.code]), [[2, 'unknown_contract_type'], [3, 'invalid_term'], [4, 'coefficient_or_rate_required'], [5, 'invalid_received_commission'], [6, 'production_shares_exceed_received_commission'], [7, 'invalid_shares'], [9, 'duplicate_row']])
})
test('import: floats in disguise are refused (exponent, thousands separator, too many decimals)', () => {
  for (const bad of ['1e-2', '1.234,5', '0.123456789']) assert.ok(mapConditionRows([HEAD, ['Novo', '84', bad, '', '7', '', '', '']], ctx).issues.length > 0, bad)
})
test('import: two groups whose names collapse to the same header are ambiguous (refused)', () => {
  const groups: GroupRef[] = [{ id: 'a', name: 'Corretor', basis: 'percent_of_production' }, { id: 'b', name: 'CORRÉTOR', basis: 'percent_of_production' }]
  assert.equal(mapConditionRows([['Tipo de Contrato', 'Prazo', 'Coeficiente', 'Comissão recebida'], ['Novo', '12', '0.1', '5']], { groups, contractTypes: T }).issues[0].code, 'ambiguous_group_names')
})
test('import: size limit and empty file', () => {
  const many = [HEAD, ...Array.from({ length: IMPORT_MAX_ROWS + 1 }, (_, i) => ['Novo', String(1 + (i % 600)), '0.01', '', '7', '', '', ''])]
  assert.equal(mapConditionRows(many, ctx).issues[0].code, 'too_many_rows')
  assert.equal(mapConditionRows([HEAD], ctx).issues[0].code, 'file_without_rows')
})
test('every import issue code has operator text', () => {
  const codes = ['file_without_rows', 'too_many_rows', 'ambiguous_group_names', 'duplicate_column', 'unknown_column', 'missing_column_contract', 'missing_column_term', 'missing_column_received', 'missing_column_coefficient_or_rate', 'unknown_contract_type', 'invalid_term', 'invalid_number', 'coefficient_or_rate_required', 'invalid_received_commission', 'invalid_shares', 'duplicate_group_share', 'commission_group_not_found', 'production_shares_exceed_received_commission', 'policy_group_inactive', 'duplicate_row']
  for (const c of codes) assert.ok(IMPORT_ISSUE_TEXT[c], c)
})

// ---- national catalogue in the migration
const MIG = 'supabase/migrations/20261002_commercial_model_v3_foundation_v1.sql'
test('migration seeds 27 governments (26 states + DF) and 26 capital city halls, none tied to a bank', () => {
  const src = read(MIG)
  const gov = [...src.matchAll(/\('(gov-[a-z]{2})','state_government'/g)].map(m => m[1])
  const pref = [...src.matchAll(/\('(pref-[a-z-]+)','capital_city_hall'/g)].map(m => m[1])
  assert.equal(gov.length, 27); assert.equal(new Set(gov).size, 27)
  assert.equal(pref.length, 26); assert.equal(new Set(pref).size, 26)
  assert.ok(gov.includes('gov-df'))
  assert.ok(!pref.includes('pref-brasilia')) // the DF has a Governo, not a Prefeitura
  assert.ok(/Governo do Distrito Federal/.test(src))
  const tpl = src.slice(src.indexOf('create table public.national_agreement_templates'), src.indexOf(');', src.indexOf('create table public.national_agreement_templates')))
  assert.ok(!/bank_id|organization_id/.test(tpl))
})
test('migration is additive and safe: no definer, no destructive statement, no float, no rename', () => {
  const src = code(read(MIG)).toLowerCase()
  assert.ok(!/security\s+definer/.test(src))
  assert.ok(!/\bdrop\s+(table|column|schema|policy|trigger|function)\b/.test(src))
  assert.ok(!/\brename\b/.test(src))
  assert.ok(!/\b(real|double\s+precision|float\d*)\b/.test(src))
  assert.ok(!/\btruncate\b|\bdelete\s+from\s+public\.(?!commercial_condition_shares)/.test(src))
  assert.ok(/enable row level security/.test(src))
  // every new table has RLS enabled
  for (const t of ['contract_types', 'national_agreement_templates', 'commercial_conditions', 'commercial_condition_commissions', 'commercial_condition_shares']) assert.ok(new RegExp(`alter table public\\.${t} enable row level security`).test(src), t)
})
test('the rollback harness covers the adversarial surface and ends with RAISE (never commits)', () => {
  const h = read('tests/security/commercial-model-v3-rollback.sql')
  for (const needle of ['forged token', 'tenant B', 'FAIL CLOSED', 'DEFINER inventory', 'no floating point', 'RESULTS:']) assert.ok(h.includes(needle), needle)
  assert.ok(/raise exception 'RESULTS:/.test(h))
  assert.ok(!/^\s*commit\s*;/im.test(code(h)))
})

// ---- application wiring
test('feedback: every database code the actions can surface has an operator message, and import/whitelist codes exist', () => {
  for (const c of ['condition_already_exists', 'invalid_shares', 'duplicate_group_share', 'commission_group_not_found', 'production_shares_exceed_received_commission', 'policy_not_found', 'policy_group_inactive', 'policy_group_must_use_received_basis', 'invalid_policy', 'policy_already_exists', 'invalid_term', 'coefficient_or_rate_required', 'invalid_received_commission', 'contract_type_not_found', 'condition_not_found', 'version_not_draft', 'national_template_not_available']) assert.ok(isFeedbackCode(`erro:com_${c}`), c)
  for (const c of ['ok:banco_cadastrado', 'ok:provedor_cadastrado', 'ok:convenio_habilitado', 'ok:convenio_cadastrado', 'ok:grupo_cadastrado', 'ok:condicao_salva', 'ok:condicoes_importadas', 'erro:import_invalido', 'erro:import_arquivo']) assert.ok(isFeedbackCode(c), c)
  for (const v of Object.values(FEEDBACK)) assert.ok(!/[a-z]+_[a-z]+_[a-z]+/.test(v.replace(/https?:\S+/g, '')), `technical text leaked: ${v}`)
})
test('actions: every write needs manager+, tenant comes from the server context, money never touches a float, the database RPC does the saving', () => {
  const a = read('src/app/app/comercial/actions.ts')
  assert.ok(/atLeast\(ctx\.membership\.role, 'manager'\)/.test(a))
  assert.ok(!/parseFloat|Number\(text|\bNumber\(.*(coefficient|rate|received|pct)/i.test(code(a)))
  assert.ok(/rpc\('save_commercial_condition'/.test(a) && /rpc\('publish_product_table_version'/.test(a))
  assert.ok(!/organization_id:\s*(text|f\.get)/.test(a)) // never a tenant taken from the form
  assert.ok(!/from\('commercial_condition(s|_commissions|_shares)'\)\.(insert|update|delete)/.test(a)) // conditions only through the governed RPC
  assert.ok(!/(text\(f, |f\.get\()'[a-z_]*(tech_key|official_code|code)'\)/.test(a)) // the person never types a technical code
})
test('page: commission is read only for commission viewers; no technical code is rendered; no manual code field', () => {
  const p = read('src/app/app/comercial/page.tsx')
  assert.ok(/canViewCommission\(membership\.role\)/.test(p))
  assert.ok(/seeCommission \?/.test(p))
  assert.ok(!/tech_key|name="code"/.test(p))
  assert.ok(/atLeast\(membership\.role, 'supervisor'\)/.test(p))
  assert.equal(canViewCommission('agent'), false)
  assert.equal(canViewCommission('supervisor'), true)
  assert.equal(atLeast('supervisor', 'manager'), false)
})
test('the two new global tables are tenant-free (no organization_id filter is added to them)', () => {
  assert.ok(TENANT_FREE_TABLES.has('contract_types') && TENANT_FREE_TABLES.has('national_agreement_templates'))
  for (const t of ['organization_banks', 'organization_providers', 'organization_agreements', 'commission_groups', 'commercial_conditions', 'commercial_condition_commissions', 'commercial_condition_shares']) assert.ok(!TENANT_FREE_TABLES.has(t), t)
})
test('setup status: V3 asks for commission groups only when the caller provides the count; legacy callers unchanged', () => {
  const states = STANDARD_STAGES.map(s => s.state)
  const legacy = setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, publishedChecklists: 1, stageStates: states, referenceReady: true })
  assert.ok(!legacy.some(i => i.key === 'groups'))
  const v3 = setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, publishedChecklists: 1, stageStates: states, referenceReady: true, commissionGroups: 0 })
  assert.equal(v3.find(i => i.key === 'groups')?.done, false)
  assert.equal(setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, publishedChecklists: 1, stageStates: states, referenceReady: true, commissionGroups: 2 }).find(i => i.key === 'groups')?.done, true)
})
test('simulation on a condition: governed RPC, amount as decimal string, condition-not-found has a message, no commission on the simulations screen for operators', () => {
  const a = read('src/app/app/simulacoes/actions.ts')
  assert.ok(/rpc\('create_simulation_for_condition'/.test(a) && /parseDecimal\(formData\.get\('requested_amount'\)/.test(a))
  assert.ok(isFeedbackCode('erro:sim_condition_not_found'))
  const p = read('src/app/app/simulacoes/page.tsx')
  assert.ok(!/commission|comiss/i.test(code(p)) || /Não calculado/.test(p))
  assert.ok(!/commercial_condition_(commissions|shares)/.test(p)) // the operator screen never reads commission or shares
})
test('import: a chosen payout policy fills the groups the file leaves blank; a typed column overrides it; nothing is typed per line', () => {
  const policy: PolicyRef = { baseKind: 'gross', discountPct: '0', items: [{ group_id: 'g-parceiro', pct: '80' }] }
  const r = mapConditionRows([['Tipo de Contrato', 'Prazo', 'Coeficiente', 'Comissão recebida', 'Parceiro'], ['Novo', '84', '0.02', '10', ''], ['Novo', '60', '0.02', '10', '70']], { groups: G, contractTypes: T, policy })
  assert.deepEqual(r.issues, [])
  assert.deepEqual(r.conditions[0].shares, []) // the file typed nothing: the database applies the policy
  assert.deepEqual(r.conditions[0].resolved.map(x => [x.group_id, x.effective, x.source]), [['g-parceiro', '8', 'policy']])
  assert.deepEqual(r.conditions[1].resolved.map(x => [x.group_id, x.effective, x.source]), [['g-parceiro', '7', 'override']])
})
test('production origin and payout policy are enforced by the database and offered by the app', () => {
  const m = read(MIG)
  assert.ok(/production_origin text check \(production_origin in \('own','third_party'\)\)/.test(m))
  assert.ok(/production_origin is not null and \(\(production_origin='own' and org_provider_id is null\) or \(production_origin='third_party' and org_provider_id is not null\)\)/.test(m)) // NULL must not slip through the CHECK
  assert.ok(/provider_type in \('bank_direct','master','promotora','correspondent','partner','other'\)/.test(m))
  assert.ok(/payout_policy_versions_are_immutable/.test(m) && /create table public\.payout_policy_versions/.test(m) && /create table public\.payout_policy_items/.test(m))
  for (const t of ['payout_policies', 'payout_policy_versions', 'payout_policy_items']) assert.ok(new RegExp(`alter table public\.${t} enable row level security`).test(m), t)
  assert.ok(!/numeric\(\d+,\d+\)\s*\)?\s*check[^;]*float/i.test(m))
  const a = read('src/app/app/comercial/actions.ts'), p = read('src/app/app/comercial/page.tsx')
  assert.ok(/production_origin: origin/.test(a) && /rpc\('save_payout_policy'/.test(a) && /p_policy_version/.test(a) && /mode'\) === 'preview'/.test(a))
  assert.ok(/name="production_origin"/.test(p) && /Própria/.test(p) && /Terceiro/.test(p) && /name="mode" value="preview"/.test(p))
  assert.ok(!/from\('payout_polic[a-z_]*'\)\.(insert|update|delete)/.test(a)) // policies only through the governed RPC
})
