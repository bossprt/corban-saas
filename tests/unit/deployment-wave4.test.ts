import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { digitsOnly, isValidCnpj, normalizeOrgName, sameOrganizationName } from '../../src/lib/platform'
import { STANDARD_STAGES, missingStages, setupItems } from '../../src/lib/catalog'
import { REQUIRED_FILES, preflight, worstLevel } from '../../src/lib/preflight'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const noLines = (src: string) => src.split('\n').filter(l => !l.trim().startsWith('--') && !l.trim().startsWith('//')).join('\n')

// ---- organization bootstrap safety
test('CNPJ: check digits, formatting ignored', () => {
  assert.equal(isValidCnpj('11.222.333/0001-81'), true)
  assert.equal(isValidCnpj('11222333000181'), true)
  for (const bad of ['11222333000182', '00000000000000', '11111111111111', '123', '', 'abc']) assert.equal(isValidCnpj(bad), false, bad)
  assert.equal(digitsOnly('11.222.333/0001-81'), '11222333000181')
})
test('organization names: the same company written differently is detected', () => {
  for (const other of ['SMART PROMOTORA', 'Smart  Promotora Ltda', 'smart promotora S.A.', 'Smart Promotóra ME']) assert.equal(sameOrganizationName('Smart Promotora', other), true, other)
  assert.equal(sameOrganizationName('Smart Promotora', 'Smart Consultoria'), false)
  assert.equal(sameOrganizationName('', ''), false)
  assert.equal(normalizeOrgName('Ação & Cia Ltda.'), 'acao')
})
test('organization route: platform admin gate, CNPJ, duplicate guards, DB-generated tenant id, compensation', () => {
  const r = read('src/app/api/admin/organizations/route.ts')
  assert.match(r, /requirePlatformAdmin\(\)/)
  assert.match(r, /isValidCnpj/)
  assert.match(r, /organization_document_exists/)
  assert.match(r, /similar_organization_exists/)
  assert.match(r, /bootstrap_organization_admin/)
  assert.doesNotMatch(r, /body\.(organizationId|organization_id|orgId|role|userId)/) // nothing that names a tenant, role or user comes from the request
  assert.match(r, /deleteUser/)
})
test('platform gate reads the closed table with the service role after a real session check', () => {
  const g = read('src/lib/platform.server.ts')
  assert.match(g, /^import 'server-only'/)
  assert.match(g, /platform_administrators/)
  assert.match(g, /auth\.getUser\(\)/)
})

// ---- reference catalog payload
test('standard stages cover the esteira but never "paid"; only missing ones are created', () => {
  assert.equal(STANDARD_STAGES.some(s => s.state === 'paid'), false)
  assert.equal(new Set(STANDARD_STAGES.map(s => s.code)).size, STANDARD_STAGES.length)
  assert.equal(missingStages([]).length, STANDARD_STAGES.length)
  assert.equal(missingStages(STANDARD_STAGES.map(s => s.state)).length, 0)
  assert.deepEqual(missingStages(['digitizing']).map(s => s.state).includes('digitizing'), false)
  assert.match(read('src/app/app/configuracao/etapas/actions.ts'), /sla_minutes: null/) // no SLA invented
})
test('setup status is computed from real counts only', () => {
  const allStates = STANDARD_STAGES.map(s => s.state)
  const empty = setupItems({ activeMembers: 1, routes: 0, publishedVersions: 0, stageStates: [], referenceReady: false })
  assert.equal(empty.filter(i => i.done).length, 0)
  const full = setupItems({ activeMembers: 3, routes: 1, publishedVersions: 1, stageStates: allStates, referenceReady: true })
  assert.equal(full.every(i => i.done), true)
  assert.equal(setupItems({ activeMembers: 1, routes: 1, publishedVersions: 1, stageStates: allStates, referenceReady: true }).find(i => i.key === 'team')?.done, false)
})
test('the catalog migration is INVOKER-only, guarded and additive', () => {
  const m = noLines(read('supabase/migrations/20260929_catalog_publish_v1.sql'))
  assert.doesNotMatch(m, /security definer/i)
  assert.doesNotMatch(m, /drop table|truncate|delete from/i)
  assert.match(m, /catalog_insert_must_be_draft/)
  assert.match(m, /corban\.catalog_rpc/)
  assert.match(m, /grant execute on function public\.publish_product_table_version\(uuid\) to authenticated/)
})

// ---- deployment: env, origin, preflight
const GOOD = { NEXT_PUBLIC_SUPABASE_URL: 'https://x.supabase.co', NEXT_PUBLIC_SUPABASE_ANON_KEY: 'anon', SUPABASE_SERVICE_ROLE_KEY: 'service', NEXT_PUBLIC_SITE_URL: 'https://app.example.com', NODE_ENV: 'production' }
const ALL_FILES = () => true
test('preflight: a complete production environment passes', () => {
  const c = preflight(GOOD, p => p !== 'vercel.json', 'v22.1.0', ['a.sql'])
  assert.equal(worstLevel(c), 'PASS')
  assert.equal(c.some(x => x.level === 'BLOCKED'), false)
})
test('preflight: every missing critical value is BLOCKED and no value is ever printed', () => {
  const secretish = 'S3CR3T-value-that-must-not-appear'
  for (const k of ['NEXT_PUBLIC_SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'NEXT_PUBLIC_SITE_URL']) {
    const env: Record<string, string | undefined> = { ...GOOD }; delete env[k]
    assert.equal(worstLevel(preflight(env, ALL_FILES, 'v22.0.0')), 'BLOCKED', k)
  }
  const c = preflight({ ...GOOD, SUPABASE_SERVICE_ROLE_KEY: secretish }, ALL_FILES, 'v22.0.0')
  assert.ok(!JSON.stringify(c).includes(secretish))
})
test('preflight: origin shape, https in production, swapped keys, leaked NEXT_PUBLIC secrets, old node, missing files', () => {
  assert.equal(worstLevel(preflight({ ...GOOD, NEXT_PUBLIC_SITE_URL: 'https://app.example.com/login' }, ALL_FILES, 'v22.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight({ ...GOOD, NEXT_PUBLIC_SITE_URL: 'http://app.example.com' }, ALL_FILES, 'v22.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight({ ...GOOD, SUPABASE_SERVICE_ROLE_KEY: 'anon' }, ALL_FILES, 'v22.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight({ ...GOOD, NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY: 'x' }, ALL_FILES, 'v22.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight(GOOD, ALL_FILES, 'v18.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight(GOOD, p => p !== 'src/proxy.ts', 'v22.0.0')), 'BLOCKED')
  assert.equal(worstLevel(preflight({ ...GOOD, NODE_ENV: 'development', NEXT_PUBLIC_SITE_URL: undefined }, ALL_FILES, 'v22.0.0')), 'WARN')
})
test('every file the preflight requires really exists', () => { for (const f of REQUIRED_FILES) assert.ok(existsSync(join(process.cwd(), f)), f) })
test('Supabase clients fail closed on missing public env', () => {
  const env = read('src/lib/env.ts')
  assert.match(env, /throw new Error/)
  for (const f of ['src/utils/supabase/server.ts', 'src/utils/supabase/middleware.ts']) { const s = read(f); assert.match(s, /publicSupabaseEnv\(\)/, f); assert.doesNotMatch(s, /process\.env\.NEXT_PUBLIC_SUPABASE_URL!/, f) }
  assert.match(read('src/lib/supabaseAdmin.ts'), /throw new Error/)
})
test('public origin: explicit setting first, same-origin fallback only, no caller-supplied path', () => {
  const s = read('src/lib/site-origin.ts')
  assert.match(s, /NEXT_PUBLIC_SITE_URL/)
  assert.match(s, /origin\.host\.toLowerCase\(\) === host/)
  for (const f of ['src/lib/team.server.ts', 'src/app/login/recuperar/actions.ts']) assert.match(read(f), /\$\{origin\}\/auth\/definir-senha/, f)
})
test('server secrets are read only by server code', () => {
  for (const f of ['src/lib/supabaseAdmin.ts']) assert.match(read(f), /^import 'server-only'/, f)
  assert.doesNotMatch(read('src/app/login/LoginForm.tsx') + read('src/app/auth/definir-senha/page.tsx'), /SERVICE_ROLE|WORKER_SECRET/)
})
test('the env document lists every variable the code reads', () => {
  const doc = read('docs/deployment/ENVIRONMENT-VARIABLES.md')
  for (const v of ['NEXT_PUBLIC_SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'NEXT_PUBLIC_SITE_URL', 'NODE_ENV']) assert.ok(doc.includes(v), v)
})
