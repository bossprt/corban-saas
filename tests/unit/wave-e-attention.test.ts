import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ALL_RULE_KEYS, evaluateRules, isSeverity, type AttentionData, type Signal } from '../../src/lib/attention-rules'
import { isFeedbackCode } from '../../src/lib/feedback'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const NOW = Date.parse('2026-09-20T12:00:00Z')
const H = 3_600_000
const sig = (count: number, hoursOld = 1, ids: string[] = ['a', 'b']): Signal => ({ count, ids, oldest: new Date(NOW - hoursOld * H).toISOString() })
const none: AttentionData = { overdueCases: null, staleLeads: null, draftProposals: null, failedRuns: null, importReviews: null, reconciliations: null }
const zero: AttentionData = { overdueCases: sig(0), staleLeads: sig(0), draftProposals: sig(0), failedRuns: sig(0), importReviews: sig(0), reconciliations: sig(0) }

test('rules: nothing detected = evaluated but empty (so cleared conditions can be auto-resolved)', () => {
  const r = evaluateRules('supervisor', zero, NOW)
  assert.deepEqual(r.candidates, [])
  assert.deepEqual([...r.evaluated].sort(), [...ALL_RULE_KEYS].sort())
})
test('rules: a signal that could not be read is NOT evaluated (never treated as zero)', () => {
  const r = evaluateRules('supervisor', { ...zero, overdueCases: null, failedRuns: null }, NOW)
  assert.ok(!r.evaluated.includes('overdue_cases') && !r.evaluated.includes('failed_runs'))
  assert.ok(r.evaluated.includes('stale_leads'))
  assert.deepEqual(evaluateRules('supervisor', none, NOW), { candidates: [], evaluated: [] })
})
test('rules: operators (agent) see and evaluate nothing; supervisor and above evaluate everything they may read', () => {
  assert.deepEqual(evaluateRules('agent', { ...zero, overdueCases: sig(50) }, NOW), { candidates: [], evaluated: [] })
  for (const role of ['supervisor', 'manager', 'admin']) assert.equal(evaluateRules(role, { ...zero, reconciliations: sig(2) }, NOW).candidates.length, 1, role)
  for (const role of [undefined, null, '', 'owner', '__proto__']) assert.deepEqual(evaluateRules(role as string, { ...zero, overdueCases: sig(5) }, NOW).candidates, [], String(role))
})
test('severity: overdue cases escalate by age and volume', () => {
  const sev = (s: Signal) => evaluateRules('manager', { ...none, overdueCases: s }, NOW).candidates[0].severity
  assert.equal(sev(sig(1, 2)), 'medium')
  assert.equal(sev(sig(3, 2)), 'high')
  assert.equal(sev(sig(1, 25)), 'high')
  assert.equal(sev(sig(1, 73)), 'critical')
  assert.equal(sev(sig(10, 1)), 'critical')
})
test('severity: failed runs, reconciliations, imports, leads, drafts', () => {
  const one = (k: keyof AttentionData, s: Signal) => evaluateRules('admin', { ...none, [k]: s }, NOW).candidates[0].severity
  assert.equal(one('failedRuns', sig(1)), 'high'); assert.equal(one('failedRuns', sig(3)), 'critical')
  assert.equal(one('reconciliations', sig(1)), 'high'); assert.equal(one('reconciliations', sig(5)), 'critical')
  assert.equal(one('importReviews', sig(1)), 'medium'); assert.equal(one('importReviews', sig(20)), 'high')
  assert.equal(one('staleLeads', sig(2, 60)), 'medium'); assert.equal(one('staleLeads', sig(2, 24 * 8)), 'high'); assert.equal(one('staleLeads', sig(20)), 'high')
  assert.equal(one('draftProposals', sig(2)), 'low'); assert.equal(one('draftProposals', sig(10)), 'medium')
})
test('candidates carry the fields the Action Center must show, sorted by severity, with bounded evidence', () => {
  const r = evaluateRules('admin', { ...zero, overdueCases: sig(2, 80, ['1', '2', '3', '4', '5', '6', '7']), draftProposals: sig(1), failedRuns: sig(1) }, NOW)
  assert.deepEqual(r.candidates.map(c => c.severity), ['critical', 'high', 'low'])
  for (const c of r.candidates) {
    assert.ok(c.title && c.reason && c.impact && c.recommendation && /^\/app(\/[a-z0-9_-]+)*$/.test(c.href), c.rule_key)
    assert.equal(c.dedupe_key, c.rule_key); assert.ok(isSeverity(c.severity)); assert.ok(c.evidence.count > 0)
  }
  assert.equal(r.candidates[0].evidence.sample_ids.length, 5)
  assert.ok(!r.candidates.some(c => /nome|cpf|cliente/i.test(JSON.stringify(c.evidence)))) // evidence is counts and ids, never personal data
})
test('rules reject malformed counts instead of guessing', () => {
  for (const bad of [-1, 1.5, Number.NaN, Infinity]) assert.deepEqual(evaluateRules('admin', { ...none, overdueCases: { count: bad, ids: [], oldest: null } }, NOW), { candidates: [], evaluated: [] })
  const junkDate = evaluateRules('admin', { ...none, overdueCases: { count: 1, ids: [], oldest: 'not a date' } }, NOW)
  assert.equal(junkDate.candidates[0].severity, 'medium')
})

test('rules never say anything about people or performance (objective signals only)', () => {
  const src = read('src/lib/attention-rules.ts')
  assert.ok(!/produtiv|desempenh|preguiç|ocios|performance de/i.test(src))
})
test('page and actions: supervisor+, decisions only through the governed RPC, dismissal needs a reason, no direct table write, no business data changed', () => {
  const a = read('src/app/app/atencao/actions.ts'), p = read('src/app/app/atencao/page.tsx') + read('src/lib/attention.server.ts')
  assert.ok(/atLeast\(membership\.role, 'supervisor'\)/.test(a) && /atLeast\(membership\.role, 'supervisor'\)/.test(p))
  assert.ok(/rpc\('decide_attention_item'/.test(a) && /rpc\('sync_attention_items'/.test(p))
  assert.ok(/note\.length < 3/.test(a))
  assert.ok(!/from\('operational_attention_(items|events)'\)\.(insert|update|delete|upsert)/.test(a + p))
  assert.ok(!/organization_id:\s*(text|f\.get)/.test(a))
  assert.ok(/evaluated/.test(p) && /não significa/.test(p)) // a failed query is shown as "could not check", not as zero
  for (const c of ['ok:atencao_atualizada', 'erro:atencao_nota', 'erro:atencao_invalida']) assert.ok(isFeedbackCode(c), c)
})
test('Action Center migration: invoker, RLS, append-only history, resolved is final, internal links only, no AI and no money', () => {
  const m = read('supabase/migrations/20261006_action_center_v1.sql').split('\n').filter(l => !l.trim().startsWith('--')).join('\n')
  assert.ok(!/security\s+definer/i.test(m))
  for (const t of ['operational_attention_items', 'operational_attention_events']) assert.ok(new RegExp(`alter table public\\.${t} enable row level security`).test(m), t)
  assert.ok(/attention_records_are_not_deletable/.test(m) && /attention_item_is_resolved/.test(m) && /note_required/.test(m))
  assert.ok(/href ~ '\^\/app/.test(m))
  assert.ok(!/\b(financial_events|commission_groups|payout_|ai_credit_ledger)\b/.test(m)) // it never touches financial or commission data
  assert.ok(!/grant[^;]*delete[^;]*operational_attention/i.test(m))
})
