import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { atLeast, canManageMemberRole, canManageTeam, canViewCommission, rolesAssignableBy } from '../../src/lib/rbac'
import { classifyTeamError, isExistingUserError, isTeamErrorCode, isUuid, normalizeEmail, TEAM_ERROR_MESSAGES } from '../../src/lib/team'
import { ENVIRONMENT_LABEL, providerEnvironment, workerReadiness } from '../../src/lib/integrations/readiness'

const ROOT = process.cwd()
const read = (p: string) => readFileSync(join(ROOT, p), 'utf8')
const walk = (dir: string): string[] => readdirSync(join(ROOT, dir)).flatMap(n => { const p = `${dir}/${n}`; return statSync(join(ROOT, p)).isDirectory() ? walk(p) : [p] })

// ---- the role matrix (must equal public.can_manage_member_role in the migration)
const ROLES = ['admin', 'manager', 'supervisor', 'agent']
test('canManageMemberRole: exhaustive matrix', () => {
  for (const actor of [...ROLES, 'owner', '', null, undefined]) for (const cur of [null, ...ROLES]) for (const next of [...ROLES, 'root', '', null]) {
    const expected =
      ROLES.includes(next as string) && (cur === null || ROLES.includes(cur)) &&
      (actor === 'admin' || (actor === 'manager' && (next === 'supervisor' || next === 'agent') && (cur === null || cur === 'supervisor' || cur === 'agent')))
    assert.equal(canManageMemberRole(actor as string, cur, next as string), expected, `${actor} ${cur} -> ${next}`)
  }
})
test('canManageMemberRole: the cases that matter', () => {
  assert.equal(canManageMemberRole('manager', null, 'admin'), false)
  assert.equal(canManageMemberRole('manager', 'admin', 'agent'), false)
  assert.equal(canManageMemberRole('manager', 'manager', 'agent'), false)
  assert.equal(canManageMemberRole('manager', 'agent', 'manager'), false)
  assert.equal(canManageMemberRole('manager', 'agent', 'supervisor'), true)
  assert.equal(canManageMemberRole('admin', 'admin', 'agent'), true)
  assert.equal(canManageMemberRole('supervisor', null, 'agent'), false)
  assert.equal(canManageMemberRole('agent', null, 'agent'), false)
  for (const bad of ['__proto__', 'constructor', 'toString']) assert.equal(canManageMemberRole('admin', null, bad), false)
})
test('rolesAssignableBy / canManageTeam', () => {
  assert.deepEqual(rolesAssignableBy('admin').sort(), ['admin', 'agent', 'manager', 'supervisor'])
  assert.deepEqual(rolesAssignableBy('manager').sort(), ['agent', 'supervisor'])
  assert.deepEqual(rolesAssignableBy('supervisor'), [])
  assert.deepEqual(rolesAssignableBy(null), [])
  assert.equal(canManageTeam('manager'), true)
  assert.equal(canManageTeam('supervisor'), false)
  assert.equal(canManageTeam(undefined), false)
})
test('the SQL predicate in the migration says the same thing as the TypeScript one', () => {
  const sql = read('supabase/migrations/20260925_team_access_lifecycle_v1.sql')
  assert.match(sql, /when p_actor='admin' then p_target_new in \('admin','manager','supervisor','agent'\)/)
  assert.match(sql, /when p_actor='manager' then p_target_new in \('supervisor','agent'\) and \(p_target_current is null or p_target_current in \('supervisor','agent'\)\)/)
  assert.match(sql, /else false end/)
})

// ---- commission visibility: one place, fail closed
test('canViewCommission is fail-closed until the Owner decides (supervisor and above)', () => {
  assert.equal(canViewCommission('agent'), false)
  for (const r of ['supervisor', 'manager', 'admin']) assert.equal(canViewCommission(r), true)
  for (const r of [undefined, null, '', 'owner', 'ADMIN', '__proto__']) assert.equal(canViewCommission(r as string), false)
  assert.equal(atLeast('supervisor', 'supervisor'), canViewCommission('supervisor'))
})
test('screens ask canViewCommission instead of hard-coding the role', () => {
  for (const f of ['src/app/app/page.tsx', 'src/app/app/financeiro/page.tsx', 'src/app/app/financeiro/casos/[id]/page.tsx', 'src/app/app/importacoes/[id]/page.tsx']) assert.match(read(f), /canViewCommission\(/, f)
})

// ---- error classification and input hygiene
test('classifyTeamError maps every governed RPC error and fails to "unexpected"', () => {
  for (const code of Object.keys(TEAM_ERROR_MESSAGES)) {
    if (code === 'unexpected' || code === 'invalid_input') continue
    assert.equal(classifyTeamError({ message: code }), code)
    assert.equal(classifyTeamError({ message: `ERROR: ${code}` }), code)
  }
  assert.equal(classifyTeamError({ code: '42501', message: 'x' }), 'not_authorized')
  assert.equal(classifyTeamError({ message: 'permission denied for function set_member_role' }), 'not_authorized')
  assert.equal(classifyTeamError({ message: 'membership_write_requires_governed_rpc' }), 'unexpected')
  assert.equal(classifyTeamError({ message: 'SQL: select * from x -- secret' }), 'unexpected')
  assert.equal(classifyTeamError(null), 'unexpected')
})
test('operator messages never leak SQL, identifiers or raw errors', () => {
  for (const m of Object.values(TEAM_ERROR_MESSAGES)) assert.doesNotMatch(m, /select |insert |rpc|uuid|postgres|pgrst|_/i)
  assert.equal(isTeamErrorCode('__proto__'), false)
  assert.equal(isTeamErrorCode('not_authorized'), true)
})
test('normalizeEmail / isUuid', () => {
  assert.equal(normalizeEmail('  Ana@Example.COM '), 'ana@example.com')
  for (const bad of ['', 'ana', 'a@', '@b', 'a b@c.d', 'x'.repeat(250) + '@e.co', null, undefined, 5]) assert.equal(normalizeEmail(bad), null, String(bad))
  assert.equal(isUuid('9116a949-18f1-4cb0-aeb8-2c89e7ea882a'), true)
  assert.equal(isUuid("'; drop table x;--"), false)
  assert.equal(isUuid(undefined), false)
})
test('an already registered address is not an invitation failure', () => {
  assert.equal(isExistingUserError({ code: 'email_exists' }), true)
  assert.equal(isExistingUserError({ message: 'A user with this email address has already been registered' }), true)
  assert.equal(isExistingUserError({ message: 'SMTP down' }), false)
  assert.equal(isExistingUserError(null), false)
})

// ---- worker readiness / provider environment
test('workerReadiness: secret strength, local guard, no values leaked', () => {
  const secret = 'S'.repeat(30)
  const r = workerReadiness({ INTEGRATION_WORKER_SECRET: secret, NODE_ENV: 'production', CORBAN_ALLOW_LOCAL_PROVIDERS: '1' })
  assert.equal(r.secretConfigured, true)
  assert.equal(r.localProvidersAllowed, false)
  assert.deepEqual(r.runnableProviders, [])
  assert.equal(r.realProviderAvailable, false)
  assert.ok(!JSON.stringify(r).includes(secret))
  assert.equal(workerReadiness({ INTEGRATION_WORKER_SECRET: 'short' }).secretConfigured, false)
  assert.equal(workerReadiness({}).secretConfigured, false)
  const dev = workerReadiness({ NODE_ENV: 'development', CORBAN_ALLOW_LOCAL_PROVIDERS: '1' })
  assert.equal(dev.localProvidersAllowed, true)
  assert.ok(dev.runnableProviders.every(k => providerEnvironment(k) === 'local_test'))
  assert.equal(dev.realProviderAvailable, false)
})
test('the fake provider can never be labelled as a bank/real provider; blocked providers are not homologated', () => {
  assert.equal(providerEnvironment('local/fake'), 'local_test')
  assert.match(ENVIRONMENT_LABEL.local_test, /LOCAL/)
  assert.doesNotMatch(ENVIRONMENT_LABEL.local_test, /BANCO REAL|PRODU|HOMOLOGADO/)
  assert.equal(providerEnvironment('bevi/webservice_agente'), 'not_homologated')
  assert.equal(providerEnvironment('2tech/busca_contrato_file'), 'not_homologated')
  assert.equal(providerEnvironment('nope/unknown'), 'not_homologated')
})

// ---- architecture: where the service role may live, what the team module may trust
test('service role and admin client stay out of client code and out of team pages', () => {
  for (const f of walk('src').filter(f => /\.(tsx?|mjs)$/.test(f))) {
    const s = read(f)
    if (/^\s*['"]use client['"]/m.test(s)) assert.doesNotMatch(s, /supabaseAdmin|SERVICE_ROLE|service_role|team\.server/, `${f} is a client file`)
  }
  assert.match(read('src/lib/team.server.ts'), /^import 'server-only'/)
  assert.doesNotMatch(read('src/app/app/equipe/page.tsx'), /supabaseAdmin|SERVICE_ROLE/)
  assert.doesNotMatch(read('src/app/access-pending/page.tsx'), /SERVICE_ROLE|createAdminClient/)
})
test('team actions never take the tenant from the form and always go through governed RPCs', () => {
  const a = read('src/app/app/equipe/actions.ts')
  assert.doesNotMatch(a, /get\(['"]organization/)
  assert.match(a, /p_org:organization\.id/)
  for (const rpc of ['create_organization_invitation', 'revoke_organization_invitation', 'set_member_role', 'set_member_status']) assert.match(a, new RegExp(rpc))
  assert.doesNotMatch(a, /\.from\(['"]organization_memberships['"]\)\s*\.(insert|update|delete)/)
})
test('acceptance only trusts a confirmed address and never runs for an unconfirmed one', () => {
  const s = read('src/lib/team.server.ts')
  assert.match(s, /email_confirmed_at/)
  assert.match(s, /accept_organization_invitations/)
})
test('e-mail link handlers never log or echo the token and use a fixed destination', () => {
  const c = read('src/app/auth/confirm/route.ts')
  assert.doesNotMatch(c, /console\./)
  assert.match(c, /\/auth\/definir-senha/)
  assert.doesNotMatch(c, /searchParams\.get\(['"](next|redirect|redirect_to|url)['"]\)/)
  assert.doesNotMatch(read('src/app/auth/definir-senha/page.tsx'), /console\./)
})
test('health endpoint exposes no configuration or secrets', () => {
  const h = read('src/app/api/health/route.ts')
  assert.doesNotMatch(h, /INTEGRATION_WORKER_SECRET|SERVICE_ROLE|createAdminClient/)
  assert.match(read('src/utils/supabase/middleware.ts'), /\/api\/health/)
})
test('the menu offers Equipe only to managers and Financeiro only to commission viewers (pages still enforce)', () => {
  const l = read('src/app/app/layout.tsx')
  assert.match(l, /href: '\/app\/equipe'[^}]*show: canManageTeam/)
  assert.match(l, /href: '\/app\/financeiro'[^}]*show: canViewCommission/)
  for (const href of ['/app/leads', '/app/clientes', '/app/simulacoes', '/app/propostas', '/app/documentos', '/app/operacao', '/app/integracoes', '/app/financeiro', '/app/equipe']) assert.ok(l.includes(`'${href}'`), href)
})
