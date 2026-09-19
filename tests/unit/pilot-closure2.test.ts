import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { OMITTED, buildAttemptHistory, groupByRun, safeText } from '../../src/lib/integrations/attempt-history'
import { actionItems } from '../../src/lib/action-center'
import { SIMULATION_ERRORS, classifySimulationError } from '../../src/lib/simulation'
import { caseStateLabel, jobStatusLabel } from '../../src/lib/operational'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const code = (src: string) => src.split('\n').filter(l => !l.trim().startsWith('--') && !l.trim().startsWith('//')).join('\n')
const row = (payload: unknown, created_at = '2026-09-24T10:00:00Z') => ({ created_at, payload })

// ---- attempt history: whitelist + hostile content
test('attempt history: ordered, labelled, whitelisted', () => {
  const h = buildAttemptHistory([
    row({ attempt: 2, outcome: 'lease_expired', at: '2026-09-24T10:05:00Z' }),
    row({ attempt: 1, outcome: 'retry_scheduled', code: 'timeout', message: 'provider timed out', retryable: true, at: '2026-09-24T10:00:00Z', extra: { raw: 'x' } }),
    row({ attempt: 3, outcome: 'failed_terminal', code: 'terminal:validation', message: 'rejected', retryable: false }),
  ])
  assert.deepEqual(h.map(a => a.attempt), [1, 2, 3])
  assert.equal(h[0].label, 'Falhou; nova tentativa agendada')
  assert.equal(h[0].retryable, true)
  assert.equal(h[1].code, null)
  assert.ok(!('extra' in h[0]) && !JSON.stringify(h).includes('"raw"'))
})
test('attempt history: secrets, JWTs, CPF, e-mail, phone, URLs with credentials, huge blobs are never shown', () => {
  const hostile = [
    'Authorization: Bearer abcdefghijklmnop', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcd1234', 'api_key=sk_live_abcdef123456',
    'cpf 123.456.789-09', 'contato ana@example.com', 'ligar 5511999998888', 'https://user:hunter2pass@example.test/x', 'A'.repeat(300), 'senha=1234', 'set-cookie: sid=1',
  ]
  for (const m of hostile) assert.equal(safeText(m), OMITTED, m)
  const h = buildAttemptHistory(hostile.map((m, i) => row({ attempt: i + 1, outcome: 'retry_scheduled', code: 'api_key=zzz', message: m })))
  const dump = JSON.stringify(h)
  for (const leak of ['Bearer', 'eyJ', 'sk_live', '123.456', 'ana@', '5511999998888', 'hunter2', 'senha=1234', 'sid=1']) assert.ok(!dump.includes(leak), leak)
  assert.ok(h.every(a => a.code === OMITTED))
})
test('attempt history: html/sql/control characters are plain text, length bounded, garbage rows ignored', () => {
  assert.equal(safeText('<script>alert(1)</script>'), '<script>alert(1)</script>') // rendered by React as TEXT, never as markup
  assert.equal(safeText("x'; drop table t;--"), "x'; drop table t;--")
  assert.equal(safeText('a\u0000b\u0007c\n\td'), 'a b c d')
  assert.ok((safeText('word '.repeat(100)) ?? '').length <= 201)
  assert.equal(safeText(''), null)
  assert.equal(safeText(42), null)
  const h = buildAttemptHistory([row(null), row('x'), row([]), row({}), row({ attempt: -1 }), row({ attempt: 1.5 }), row({ attempt: 1e9 }), row({ attempt: 1, outcome: 'weird' }), null as never, undefined as never])
  assert.equal(h.length, 1)
  assert.equal(h[0].outcome, 'unknown')
  assert.deepEqual(buildAttemptHistory(null), [])
})
test('attempt history: groupByRun keeps runs apart (no cross-run mixing)', () => {
  const g = groupByRun([{ run_id: 'a', n: 1 }, { run_id: 'b', n: 2 }, { run_id: 'a', n: 3 }])
  assert.deepEqual(g.get('a')?.map(x => x.n), [1, 3])
  assert.deepEqual(g.get('b')?.map(x => x.n), [2])
})
test('integrations page renders history as text only and never dumps payloads', () => {
  const p = read('src/app/app/integracoes/page.tsx')
  assert.doesNotMatch(p, /dangerouslySetInnerHTML/)
  assert.match(p, /buildAttemptHistory/)
  assert.doesNotMatch(p, /JSON\.stringify|\.payload\b(?!\))/)
})

// ---- action center: deterministic and role-aware
test('action center: role gates, zero suppression, null safety, fixed order', () => {
  const all = { staleLeads: 2, draftProposals: 3, overdueCases: 1, failedRuns: 4, reconciliations: 5, importReviews: 6 }
  assert.deepEqual(actionItems('agent', all).map(i => i.key), ['overdueCases', 'draftProposals', 'staleLeads'])
  assert.deepEqual(actionItems('supervisor', all).map(i => i.key), ['overdueCases', 'draftProposals', 'staleLeads', 'failedRuns', 'importReviews', 'reconciliations'])
  assert.deepEqual(actionItems('admin', all).length, 6)
  for (const r of [undefined, null, '', 'owner', '__proto__']) assert.deepEqual(actionItems(r as string, all).map(i => i.key).filter(k => ['failedRuns', 'reconciliations', 'importReviews'].includes(k)), [])
  assert.deepEqual(actionItems('admin', { staleLeads: 0, draftProposals: null, overdueCases: undefined, failedRuns: NaN, reconciliations: -3 }), [])
  assert.equal(actionItems('manager', { staleLeads: 2.9 })[0].count, 2)
})
test('dashboard does not even query what the role may not see', () => {
  const d = read('src/app/app/page.tsx')
  assert.match(d, /canSeeFinance \? supabase\.from\('financial_reconciliation_cases'\)/)
  assert.match(d, /canSeeFinance \? supabase\.from\('financial_events'\)/)
  assert.match(d, /canSeeIntegrations \? supabase\.from\('integration_runs'\)/)
})

// ---- simulations
test('simulation errors: classified, actionable, no internals', () => {
  for (const c of Object.keys(SIMULATION_ERRORS)) if (c !== 'unexpected' && c !== 'rpc_unavailable') assert.equal(classifySimulationError({ message: c }), c)
  assert.equal(classifySimulationError({ code: 'PGRST202', message: 'x' }), 'rpc_unavailable')
  assert.equal(classifySimulationError({ message: 'Could not find the function public.create_simulation' }), 'rpc_unavailable')
  assert.equal(classifySimulationError({ code: '42501', message: 'permission denied' }), 'not_authorized')
  assert.equal(classifySimulationError({ message: 'simulation_write_requires_governed_rpc' }), 'unexpected')
  for (const m of Object.values(SIMULATION_ERRORS)) assert.doesNotMatch(m, /select |rpc |uuid|postgres|_[a-z]+_/i)
})
test('simulation action: the RPC is the primary path; nothing but ids and two numbers comes from the form', () => {
  const a = read('src/app/app/simulacoes/actions.ts')
  assert.match(a, /supabase\.rpc\('create_simulation'/)
  const primary = a.slice(a.indexOf('export async function createSimulation'), a.indexOf('export async function createProposalFromSimulation'))
  assert.doesNotMatch(primary, /formData\.get\('(organization|created_by|expected|commission|rate|coefficient|installment)/)
  // the pre-migration fallback exists ONLY behind rpc_unavailable and never sets a commission
  assert.match(a, /code === 'rpc_unavailable'/)
  assert.doesNotMatch(a, /expected_commission_amount/)
})
test('the migration governs simulations the way the action expects', () => {
  const m = read('supabase/migrations/20260926_simulation_governance_v1.sql')
  assert.match(m, /corban\.simulation_rpc/)
  assert.match(m, /create trigger simulations_00_governed_write/)
  assert.doesNotMatch(code(m), /security definer/i)
  assert.doesNotMatch(code(m), /drop table|truncate|delete from/i)
})

// ---- password recovery and auth links
test('recovery: identical public answer for any e-mail, no auth of our own, fixed redirect', () => {
  const a = read('src/app/login/recuperar/actions.ts')
  assert.match(a, /resetPasswordForEmail/)
  assert.match(a, /redirect\('\/login\/recuperar\?enviado=1'\)/)
  assert.doesNotMatch(a, /console\.|getUserByEmail|listUsers|createAdminClient|SERVICE_ROLE/)
  assert.match(a, /\/auth\/definir-senha/)
  // the only branch that differs is a malformed address (client-visible input error), never account existence
  assert.equal((a.match(/redirect\(/g) ?? []).length, 2)
})
test('recovery page never reveals whether the address exists', () => {
  const p = read('src/app/login/recuperar/page.tsx')
  assert.match(p, /Se este e-mail tiver um acesso/)
  assert.doesNotMatch(p, /não encontrado|não existe|cadastrado/i)
})
test('/auth/confirm: strict token shape, type allow-list, fixed destination, no token echo/log', () => {
  const c = read('src/app/auth/confirm/route.ts')
  assert.match(c, /TOKEN_SHAPE/)
  assert.match(c, /ALLOWED_TYPES/)
  assert.doesNotMatch(c, /console\.|searchParams\.get\('(next|redirect|redirect_to|url|returnTo)'\)/)
  assert.ok((c.match(/NextResponse\.redirect\(new URL\('/g) ?? []).length === 2)
  assert.doesNotMatch(c, /new URL\([^)]*tokenHash/) // never placed in a redirect URL
})
test('site origin helper is server-only and accepts only http(s)', () => {
  const s = read('src/lib/site-origin.ts')
  assert.match(s, /^import 'server-only'/)
  assert.match(s, /https:|http:/)
})
test('login page links to recovery', () => {
  assert.match(read('src/app/login/LoginForm.tsx'), /href="\/login\/recuperar"/)
})

// ---- operation UX and language
test('esteira labels: every canonical state has a label and a next step; no screen offers a manual PAID', () => {
  for (const s of ['digitization_queue', 'digitizing', 'submitted', 'pending_external', 'approved', 'rejected', 'cancelled', 'paid']) assert.ok(caseStateLabel(s).label && caseStateLabel(s).next, s)
  assert.equal(caseStateLabel('zzz').label, 'Situação desconhecida')
  assert.equal(jobStatusLabel('zzz'), 'Situação desconhecida')
  assert.match(caseStateLabel('approved').next, /evidência/)
  const op = read('src/app/app/operacao/page.tsx')
  assert.doesNotMatch(op, /value="paid"/)
  for (const f of ['src/app/app/propostas/[id]/page.tsx', 'src/app/app/propostas/page.tsx', 'src/app/app/clientes/page.tsx']) assert.doesNotMatch(read(f), /Marcar como pago|value="paid"/i, f)
})
test('the proposal page does not pull the commission column into memory for anyone', () => {
  assert.doesNotMatch(read('src/app/app/propostas/[id]/page.tsx'), /expected_commission_amount/)
})
test('health probe is cached and minimal', () => {
  const h = read('src/app/api/health/route.ts')
  assert.match(h, /CACHE_MS/)
  assert.doesNotMatch(code(h), /INTEGRATION_WORKER_SECRET|SERVICE_ROLE|provider|adapter/i)
})
