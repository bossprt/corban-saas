import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileFingerprint, layoutFingerprint, reuseDecision, validateProposal, type SavedMapping } from '../../src/lib/ai-import/validate'
import { buildGeminiPrompt, geminiMapper, heuristicMapper, parseGeminiAnswer, scriptedMapper } from '../../src/lib/ai-import/providers'
import { estimateCredits, proposeMapping, type MeteringPort, type RateCard } from '../../src/lib/ai-import/orchestrator'
import type { MappingProposal, MappingRequest } from '../../src/lib/ai-import/types'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const HEAD = ['Banco', 'Convênio', 'Tipo de Contrato', 'Prazo', 'Coeficiente', 'Taxa', 'Comissão recebida', 'Observação']
const SAMPLE = [['Pan', 'Governo do Acre', 'Novo', '84', '0,0190', '1,85', '7,00', 'x'], ['Pan', 'Governo do Acre', 'Refinanciamento', '96', '0,0180', '1,90', '6,50', '']]
const req = (over: Partial<MappingRequest> = {}): MappingRequest => ({ sourceLabel: 'Pan', fingerprint: layoutFingerprint(HEAD), headers: HEAD, sample: SAMPLE, ...over })
const good = (over: Partial<MappingProposal> = {}): MappingProposal => ({
  provider: 't', model: 'm', overallConfidence: 0.95, usage: { inputUnits: 100, outputUnits: 20 },
  fields: [
    { field: 'bank', column: 'Banco', confidence: 0.99, evidence: 'nome' }, { field: 'agreement', column: 'Convênio', confidence: 0.95, evidence: '' },
    { field: 'contract_type', column: 'Tipo de Contrato', confidence: 0.97, evidence: '' }, { field: 'term', column: 'Prazo', confidence: 0.99, evidence: '' },
    { field: 'coefficient', column: 'Coeficiente', confidence: 0.96, evidence: '' }, { field: 'rate', column: 'Taxa', confidence: 0.9, evidence: '' },
    { field: 'received_commission', column: 'Comissão recebida', confidence: 0.93, evidence: '' },
  ], ...over,
})

test('layout fingerprint: stable for case/accent/punctuation, changes when a column is renamed, added or moved', () => {
  assert.equal(layoutFingerprint(HEAD), layoutFingerprint(HEAD.map(h => h.toUpperCase())))
  assert.match(layoutFingerprint(HEAD), /^[0-9a-f]{64}$/)
  assert.notEqual(layoutFingerprint(HEAD), layoutFingerprint([...HEAD, 'Nova']))
  assert.notEqual(layoutFingerprint(HEAD), layoutFingerprint([HEAD[1], HEAD[0], ...HEAD.slice(2)]))
  assert.notEqual(layoutFingerprint(HEAD), layoutFingerprint(HEAD.map(h => (h === 'Taxa' ? 'Taxa mensal' : h))))
  assert.equal(fileFingerprint(new Uint8Array([1, 2, 3])), fileFingerprint(new Uint8Array([1, 2, 3])))
  assert.notEqual(fileFingerprint(new Uint8Array([1, 2, 3])), fileFingerprint(new Uint8Array([1, 2, 4])))
})

test('validator: a clean proposal needs no review, and unknown columns are recomputed from the headers (never trusted from the model)', () => {
  const v = validateProposal(req(), good())
  assert.equal(v.needsReview, false)
  assert.equal(v.mapping.term, 'Prazo')
  assert.deepEqual(v.unknownColumns, ['Observação'])
  assert.ok(v.items.filter(i => ['valid_from', 'valid_until', 'product_table', 'production_origin'].includes(i.field)).every(i => i.status === 'missing'))
})
test('validator: an invented column is dropped, never mapped', () => {
  const p = good(); p.fields[3] = { field: 'term', column: 'Meses do contrato', confidence: 0.99, evidence: '' }
  const v = validateProposal(req(), p)
  assert.equal(v.mapping.term, undefined)
  assert.equal(v.items.find(i => i.field === 'term')?.status, 'missing')
  assert.equal(v.needsReview, true)
})
test('validator: money fields need high confidence AND numeric evidence in the sample; the model cannot buy trust', () => {
  const low = good(); low.fields[5] = { field: 'rate', column: 'Taxa', confidence: 0.5, evidence: '' }
  assert.equal(validateProposal(req(), low).items.find(i => i.field === 'rate')?.status, 'review')
  const wrong = good(); wrong.fields[4] = { field: 'coefficient', column: 'Observação', confidence: 1, evidence: 'looks right' }
  const w = validateProposal(req(), wrong)
  assert.equal(w.items.find(i => i.field === 'coefficient')?.status, 'review')
  assert.ok(w.items.find(i => i.field === 'coefficient')?.reasons.some(r => /exemplo/.test(r)))
  assert.equal(w.needsReview, true)
  assert.equal(validateProposal(req({ sample: [] }), good()).needsReview, true)
})
test('validator: duplicate column, repeated field, unknown field and out-of-range confidence are neutralised', () => {
  const p = good()
  p.fields.push({ field: 'rate', column: 'Coeficiente', confidence: 1, evidence: '' }, { field: 'salary' as never, column: 'Banco', confidence: 1, evidence: '' })
  p.fields[2] = { field: 'contract_type', column: 'Prazo', confidence: 7, evidence: '' }
  const v = validateProposal(req(), p)
  assert.equal(v.items.filter(i => i.field === 'rate').length, 1)
  assert.ok(!v.items.some(i => (i.field as string) === 'salary'))
  assert.ok(v.items.every(i => i.confidence >= 0 && i.confidence <= 1))
  assert.equal(new Set(Object.values(v.mapping)).size, Object.values(v.mapping).length)
  assert.ok(v.items.find(i => i.field === 'term')?.reasons.some(r => /dois campos/.test(r)))
})

const saved = (over: Partial<SavedMapping> = {}): SavedMapping => ({ fingerprint: layoutFingerprint(HEAD), mapping: { term: 'Prazo', coefficient: 'Coeficiente' }, unknownColumns: ['Observação', 'Banco', 'Convênio', 'Tipo de Contrato', 'Taxa', 'Comissão recebida'], ...over })
test('memory: only an identical layout is reused; anything else goes back to review', () => {
  assert.deepEqual(reuseDecision(saved(), req()), { kind: 'reuse', mapping: { term: 'Prazo', coefficient: 'Coeficiente' } })
  assert.deepEqual(reuseDecision(null, req()), { kind: 'review', reason: 'no_memory' })
  const dropped = HEAD.filter(h => h !== 'Prazo')
  assert.deepEqual(reuseDecision(saved(), req({ headers: dropped, fingerprint: layoutFingerprint(dropped) })), { kind: 'review', reason: 'column_missing' })
  const added = [...HEAD, 'Vigência']
  assert.deepEqual(reuseDecision(saved(), req({ headers: added, fingerprint: layoutFingerprint(added) })), { kind: 'review', reason: 'new_columns' })
  const moved = [HEAD[1], HEAD[0], ...HEAD.slice(2)]
  assert.deepEqual(reuseDecision(saved(), req({ headers: moved, fingerprint: layoutFingerprint(moved) })), { kind: 'review', reason: 'layout_changed' })
})

test('heuristic mapper (no AI, no cost) finds the obvious headers and is only a suggestion', async () => {
  const p = await heuristicMapper().mapColumns(req())
  const by = Object.fromEntries(p.fields.map(f => [f.field, f.column]))
  assert.equal(by.term, 'Prazo'); assert.equal(by.coefficient, 'Coeficiente'); assert.equal(by.received_commission, 'Comissão recebida'); assert.equal(by.contract_type, 'Tipo de Contrato')
  assert.deepEqual(p.usage, { inputUnits: 0, outputUnits: 0 })
})

const KEY = 'test-key-not-a-secret'
const okBody = (text: string) => ({ candidates: [{ content: { parts: [{ text }] } }], usageMetadata: { promptTokenCount: 321, candidatesTokenCount: 45 } })
const fetchOf = (status: number, body: unknown, spy?: (url: string, init: RequestInit) => void): typeof fetch => (async (url: string | URL | Request, init?: RequestInit) => { spy?.(String(url), init ?? {}); return new Response(JSON.stringify(body), { status }) }) as typeof fetch
test('Gemini adapter: key only in the header, fixed host, prompt without key, strict answer, usage reported', async () => {
  let seen: { url: string; init: RequestInit } | null = null
  const answer = JSON.stringify({ fields: [{ field: 'term', column: 'Prazo', confidence: 0.98, evidence: 'ok' }, { field: 'salary', column: 'X', confidence: 1, evidence: '' }], overallConfidence: 0.9 })
  const m = geminiMapper({ apiKey: KEY, model: 'gemini-test', fetchImpl: fetchOf(200, okBody(answer), (url, init) => { seen = { url, init } }) })
  const p = await m.mapColumns(req())
  assert.equal(p.provider, 'gemini'); assert.deepEqual(p.usage, { inputUnits: 321, outputUnits: 45 })
  assert.deepEqual(p.fields.map(f => f.field), ['term'])
  assert.ok(seen); const s = seen as { url: string; init: RequestInit }
  assert.match(s.url, /^https:\/\/generativelanguage\.googleapis\.com\/v1beta\/models\/gemini-test:generateContent$/)
  assert.equal((s.init.headers as Record<string, string>)['x-goog-api-key'], KEY)
  assert.ok(!s.url.includes(KEY) && !String(s.init.body).includes(KEY))
  assert.match(String(s.init.body), /"temperature":0/)
})
test('Gemini adapter: every failure becomes one opaque code (no body, no key, no URL); the prompt limits rows and cell size', async () => {
  const cases: [typeof fetch, string][] = [
    [fetchOf(500, { error: `echo ${KEY}` }), 'mapper_http_500'], [fetchOf(200, {}), 'mapper_empty_answer'], [fetchOf(200, okBody('not json')), 'mapper_bad_json'], [fetchOf(200, okBody('[1]')), 'mapper_bad_shape'],
    [fetchOf(200, okBody('{"fields":[{"field":"term","column":5,"confidence":1}]}')), 'mapper_bad_shape'], [fetchOf(200, okBody('{"fields":[{"field":"term","column":"Prazo","confidence":"high"}]}')), 'mapper_bad_shape'],
  ]
  for (const [f, code] of cases) await assert.rejects(geminiMapper({ apiKey: KEY, model: 'm', fetchImpl: f }).mapColumns(req()), (e: Error) => e.message === code && !e.message.includes(KEY))
  const boom = (async () => { throw new Error(`connect failed https://x/?key=${KEY}`) }) as unknown as typeof fetch
  await assert.rejects(geminiMapper({ apiKey: KEY, model: 'm', fetchImpl: boom }).mapColumns(req()), (e: Error) => e.message === 'mapper_unavailable')
  assert.throws(() => geminiMapper({ apiKey: '', model: 'm' }), /gemini_not_configured/)
  assert.throws(() => geminiMapper({ apiKey: KEY, model: '' }), /gemini_not_configured/)
  const long = { ...req(), sample: Array.from({ length: 50 }, () => ['x'.repeat(500), 'b']) }
  const prompt = buildGeminiPrompt(long, 15)
  assert.ok(!prompt.includes(KEY) && !prompt.includes('x'.repeat(61)))
  assert.equal((prompt.match(/"x{60}"/g) ?? []).length, 15)
  assert.deepEqual(parseGeminiAnswer('```json\n{"fields":[],"overallConfidence":0.4}\n```'), { fields: [], overallConfidence: 0.4 })
})

function fakeMetering(opts: { enabled?: boolean; balance?: number; limit?: number; failSettle?: boolean } = {}) {
  const st = { enabled: opts.enabled ?? true, balance: opts.balance ?? 100, limit: opts.limit ?? 1000, used: 0, jobs: new Map<string, { id: string; est: number; status: string; charged: number }>(), reserves: 0, settles: [] as string[] }
  const port: MeteringPort = {
    async reserve(i) {
      const existing = st.jobs.get(i.idempotencyKey)
      if (existing) return { ok: true, jobId: existing.id }
      const est = Number(i.estimatedCredits)
      if (!st.enabled) return { ok: false, reason: 'ai_disabled' }
      if (st.balance < est) return { ok: false, reason: 'insufficient_credits' }
      if (st.used + est > st.limit) return { ok: false, reason: 'monthly_limit_exceeded' }
      st.balance -= est; st.used += est; st.reserves++
      st.jobs.set(i.idempotencyKey, { id: `job-${st.reserves}`, est, status: 'reserved', charged: 0 })
      return { ok: true, jobId: `job-${st.reserves}` }
    },
    async settle(i) {
      if (opts.failSettle && i.outcome === 'failed') throw new Error('db down')
      const job = [...st.jobs.values()].find(j => j.id === i.jobId)!
      st.settles.push(i.outcome)
      st.balance += job.est - Number(i.creditsCharged ?? 0); job.status = i.outcome; job.charged = Number(i.creditsCharged ?? 0)
    },
  }
  return { port, st }
}
const CARD: RateCard = { inputUnitsPerCredit: 1000, outputUnitsPerCredit: 500, minimumCredits: 0.5 }
const memory = (s: SavedMapping | null) => ({ find: async () => s })
test('estimate: closed without a rate card, fixed-decimal string, never below the minimum', () => {
  assert.equal(estimateCredits(null, req()), null)
  assert.equal(estimateCredits({ inputUnitsPerCredit: 0, outputUnitsPerCredit: 1, minimumCredits: 1 }, req()), null)
  assert.equal(estimateCredits({ inputUnitsPerCredit: 1, outputUnitsPerCredit: 1, minimumCredits: 0 }, req()), null)
  const e = estimateCredits(CARD, req())!
  assert.match(e, /^\d+\.\d{4}$/)
  assert.ok(Number(e) >= 0.5)
  assert.equal(estimateCredits({ inputUnitsPerCredit: 1e9, outputUnitsPerCredit: 1e9, minimumCredits: 0.0001 }, req()), '0.0001')
})
test('orchestrator: a reusable memory costs nothing and calls nothing', async () => {
  const { port, st } = fakeMetering(); let called = 0
  const r = await proposeMapping({ request: req(), mapper: scriptedMapper(() => { called++; throw new Error('x') }), memory: memory(saved()), metering: port, rateCard: CARD, idempotencyKey: 'key-00000001' })
  assert.equal(r.kind, 'reused'); assert.equal(called, 0); assert.equal(st.reserves, 0)
})
test('orchestrator: no mapper, no rate card, AI off, no balance, monthly ceiling: always manual, provider never called', async () => {
  let called = 0
  const mapper = scriptedMapper(() => { called++; throw new Error('x') })
  const cases: [string, Parameters<typeof proposeMapping>[0]][] = [
    ['no_mapper', { request: req(), mapper: null, memory: memory(null), metering: fakeMetering().port, rateCard: CARD, idempotencyKey: 'key-00000002' }],
    ['no_rate_card', { request: req(), mapper, memory: memory(null), metering: fakeMetering().port, rateCard: null, idempotencyKey: 'key-00000003' }],
    ['ai_disabled', { request: req(), mapper, memory: memory(null), metering: fakeMetering({ enabled: false }).port, rateCard: CARD, idempotencyKey: 'key-00000004' }],
    ['insufficient_credits', { request: req(), mapper, memory: memory(null), metering: fakeMetering({ balance: 0.1 }).port, rateCard: CARD, idempotencyKey: 'key-00000005' }],
    ['monthly_limit_exceeded', { request: req(), mapper, memory: memory(null), metering: fakeMetering({ limit: 0.1 }).port, rateCard: CARD, idempotencyKey: 'key-00000006' }],
  ]
  for (const [reason, a] of cases) { const r = await proposeMapping(a); assert.deepEqual([r.kind, (r as { reason?: string }).reason], ['manual', reason], reason) }
  assert.equal(called, 0)
})
test('orchestrator: success reserves, calls once, settles, returns a validated proposal for HUMAN review', async () => {
  const { port, st } = fakeMetering({ balance: 10 })
  const r = await proposeMapping({ request: req(), mapper: scriptedMapper({ fields: good().fields, overallConfidence: 0.9, usage: { inputUnits: 10, outputUnits: 5 } }), memory: memory(null), metering: port, rateCard: CARD, idempotencyKey: 'key-00000007' })
  assert.equal(r.kind, 'proposed')
  assert.deepEqual(st.settles, ['succeeded']); assert.ok(st.balance < 10 && st.balance > 9)
  if (r.kind === 'proposed') { assert.equal(r.validated.mapping.term, 'Prazo'); assert.deepEqual(r.validated.unknownColumns, ['Observação']) }
})
test('orchestrator: a provider failure releases the reservation (nothing charged) and falls back to manual, even if the release itself fails', async () => {
  for (const failSettle of [false, true]) {
    const { port, st } = fakeMetering({ balance: 10, failSettle })
    const r = await proposeMapping({ request: req(), mapper: scriptedMapper(() => { throw new Error('mapper_http_500') }), memory: memory(null), metering: port, rateCard: CARD, idempotencyKey: `key-fail-000${failSettle ? 2 : 1}` })
    assert.deepEqual([r.kind, (r as { reason?: string }).reason], ['manual', 'mapper_failed'])
    if (!failSettle) { assert.deepEqual(st.settles, ['failed']); assert.equal(st.balance, 10) }
  }
})
test('orchestrator: the same idempotency key never reserves twice', async () => {
  const { port, st } = fakeMetering({ balance: 10 })
  const mapper = scriptedMapper({ fields: good().fields, overallConfidence: 0.9, usage: { inputUnits: 1, outputUnits: 1 } })
  await proposeMapping({ request: req(), mapper, memory: memory(null), metering: port, rateCard: CARD, idempotencyKey: 'same-key-0001' })
  await proposeMapping({ request: req(), mapper, memory: memory(null), metering: port, rateCard: CARD, idempotencyKey: 'same-key-0001' })
  assert.equal(st.reserves, 1)
})

const walk = (d: string): string[] => readdirSync(join(process.cwd(), d), { withFileTypes: true }).flatMap(e => (e.isDirectory() ? walk(`${d}/${e.name}`) : [`${d}/${e.name}`]))
test('AI foundation: no secret, no environment access, no provider name outside the adapter, no parseFloat', () => {
  for (const f of walk('src/lib/ai-import')) {
    const t = read(f)
    assert.ok(!/process\.env/.test(t), f)
    assert.ok(!/AIza[0-9A-Za-z_-]{20,}|sk-[A-Za-z0-9]{20,}/.test(t), f)
    if (!f.endsWith('providers.ts')) assert.ok(!/generativelanguage|gemini/i.test(t.replace(/\/\/.*$/gm, '')), `${f} must stay provider-agnostic`)
  }
  assert.ok(!/parseFloat/.test(read('src/lib/ai-import/orchestrator.ts')))
})
test('metering migration: invoker, RLS on every table, append-only ledger, platform-only grants, AI off by default, no float', () => {
  const m = read('supabase/migrations/20261005_ai_import_metering_v1.sql').split('\n').filter(l => !l.trim().startsWith('--')).join('\n')
  assert.ok(!/security\s+definer/i.test(m))
  for (const t of ['import_layout_mappings', 'organization_ai_limits', 'ai_usage_jobs', 'ai_credit_ledger', 'ai_usage_events']) assert.ok(new RegExp(`alter table public\\.${t} enable row level security`).test(m), t)
  assert.ok(/enabled boolean not null default false/.test(m))
  assert.ok(/ai_records_are_append_only/.test(m) && /job_already_settled/.test(m))
  assert.ok(/grant execute on function public\.platform_grant_ai_credits\([^)]*\) to service_role/.test(m) && /revoke all on function public\.platform_grant_ai_credits\([^)]*\) from public,anon,authenticated/.test(m))
  assert.ok(!/\b(real|double precision|float\d*)\b/i.test(m))
  assert.ok(!/grant[^;]*(update|delete)[^;]*ai_credit_ledger/i.test(m))
})
