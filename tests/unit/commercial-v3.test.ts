import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { normalizeHeader, parseDecimal, parseDelimited, parseTerm } from '../../src/lib/commercial'
import { FEEDBACK, isFeedbackCode } from '../../src/lib/feedback'
import { setupItems, STANDARD_STAGES } from '../../src/lib/catalog'
import { TENANT_FREE_TABLES } from '../../src/lib/tenant'
import { atLeast, canViewCommission } from '../../src/lib/rbac'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const code = (src: string) => src.split('\n').filter(l => !l.trim().startsWith('--') && !l.trim().startsWith('//')).join('\n')

// ---- numbers: never a float
test('decimals are canonical strings: comma, percent sign and leading zeros are normalised; everything ambiguous is refused', () => {
  assert.equal(parseDecimal('1,85', { maxInt: 3, scale: 6 }), '1.85')
  assert.equal(parseDecimal(' 7% ', { maxInt: 3, scale: 6 }), '7')
  assert.equal(parseDecimal('007.50', { maxInt: 3, scale: 6 }), '7.50')
  assert.equal(parseDecimal('0,01234567', { maxInt: 6, scale: 8 }), '0.01234567')
  for (const bad of ['1e3', '-1', '1.2.3', '1.234,5', 'abc', '0.1234567', '1000']) assert.equal(parseDecimal(bad, { maxInt: 3, scale: 6 }), null, bad)
  assert.equal(parseDecimal('0.123456789', { maxInt: 6, scale: 8 }), null) // 9 decimals do not fit numeric(14,8)
})
test('term is an integer 1..600', () => {
  for (const [v, want] of [['84', 84], ['1', 1], ['600', 600], ['0', null], ['601', null], ['12.5', null], ['-3', null], ['abc', null], ['', null]] as const) assert.equal(parseTerm(v), want, v)
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

// ---- application wiring
test('feedback: every database code the actions can surface has an operator message', () => {
  assert.ok(isFeedbackCode('erro:com_national_template_not_available'))
  for (const c of ['ok:banco_cadastrado', 'ok:provedor_cadastrado', 'ok:convenio_habilitado', 'ok:convenio_cadastrado', 'ok:grupo_cadastrado']) assert.ok(isFeedbackCode(c), c)
  for (const v of Object.values(FEEDBACK)) assert.ok(!/[a-z]+_[a-z]+_[a-z]+/.test(v.replace(/https?:\S+/g, '')), `technical text leaked: ${v}`)
})
test('actions: every write needs manager+, tenant comes from the server context, money never touches a float', () => {
  const a = read('src/app/app/comercial/actions.ts')
  assert.ok(/atLeast\(ctx\.membership\.role, 'manager'\)/.test(a))
  assert.ok(!/parseFloat|Number\(text|\bNumber\(.*(coefficient|rate|received|pct)/i.test(code(a)))
  assert.ok(!/organization_id:\s*(text|f\.get)/.test(a)) // never a tenant taken from the form
  assert.ok(!/from\('commercial_condition(s|_commissions|_shares)'\)\.(insert|update|delete)/.test(a)) // conditions only through the governed RPC
  assert.ok(!/(text\(f, |f\.get\()'[a-z_]*(tech_key|official_code|code)'\)/.test(a)) // the person never types a technical code
})
test('RBAC helpers used by the commercial screens keep their matrix', () => {
  assert.equal(canViewCommission('agent'), false)
  assert.equal(canViewCommission('supervisor'), true)
  assert.equal(atLeast('supervisor', 'manager'), false)
})
test('the two new global tables are tenant-free (no organization_id filter is added to them)', () => {
  assert.ok(TENANT_FREE_TABLES.has('contract_types') && TENANT_FREE_TABLES.has('national_agreement_templates'))
  for (const t of ['organization_banks', 'organization_providers', 'organization_agreements', 'commission_groups', 'commercial_conditions']) assert.ok(!TENANT_FREE_TABLES.has(t), t)
  for (const t of ['banks', 'agreements', 'providers', 'products', 'modalities']) assert.ok(!TENANT_FREE_TABLES.has(t), `${t} was removed in part C5`)
})
test('setup status: V3 asks for commission groups only when the caller provides the count; legacy callers unchanged', () => {
  const states = STANDARD_STAGES.map(s => s.state)
  const legacy = setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, stageStates: states, referenceReady: true })
  assert.ok(!legacy.some(i => i.key === 'groups'))
  const v3 = setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, stageStates: states, referenceReady: true, commissionGroups: 0 })
  assert.equal(v3.find(i => i.key === 'groups')?.done, false)
  assert.equal(setupItems({ activeMembers: 2, routes: 1, publishedVersions: 1, stageStates: states, referenceReady: true, commissionGroups: 2 }).find(i => i.key === 'groups')?.done, true)
})
test('simulation on a condition: governed RPC, amount as decimal string, condition-not-found has a message, no commission on the simulations screen for operators', () => {
  const a = read('src/app/app/simulacoes/actions.ts')
  assert.ok(/rpc\('create_simulation_for_condition'/.test(a) && /money\(formData\.get\('requested_amount'\)\)/.test(a) && /parseMoneyInput/.test(a) && !/Number\(/.test(a))
  assert.ok(isFeedbackCode('erro:sim_condition_not_found'))
  const p = ['page', 'SimulatorPanel', 'SavedSimulations'].map(f => read(`src/app/app/simulacoes/${f}.tsx`)).join(' ')
  assert.ok(!/commission|comiss/i.test(code(p).replace(/use_in_commission/g, ''))) // the contract-type flag is not commission data
  assert.ok(!/commercial_condition_(commissions|shares)/.test(p)) // the operator screen never reads commission or shares
})
test('production origin is enforced by the database and offered by the app', () => {
  const m = read(MIG)
  assert.ok(/production_origin text check \(production_origin in \('own','third_party'\)\)/.test(m))
  assert.ok(/production_origin is not null and \(\(production_origin='own' and org_provider_id is null\) or \(production_origin='third_party' and org_provider_id is not null\)\)/.test(m)) // NULL must not slip through the CHECK
  assert.ok(/provider_type in \('bank_direct','master','promotora','correspondent','partner','other'\)/.test(m))
  assert.ok(!/numeric\(\d+,\d+\)\s*\)?\s*check[^;]*float/i.test(m))
  const a = read('src/app/app/comercial/actions.ts')
  assert.ok(/production_origin: origin/.test(a))
})
