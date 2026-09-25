import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { classifyAuthProbe, classifyRestProbe, failureProbe } from '../../src/lib/health'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const code = (s: string) => s.split('\n').filter(l => !l.trim().startsWith('//')).join('\n')

test('REST root with a publishable key (401 "Secret API key required") is NOT what the probe uses any more', () => {
  assert.doesNotMatch(code(read('src/app/api/health/route.ts')), /\/rest\/v1\/`/)
  assert.match(code(read('src/app/api/health/route.ts')), /\/rest\/v1\/organizations\?select=id&limit=1/)
  assert.match(code(read('src/app/api/health/route.ts')), /\/auth\/v1\/health/)
})
test('database probe: Postgres permission error (42501) or rows prove reachability', () => {
  assert.deepEqual(classifyRestProbe(200, []), { ok: true })
  assert.deepEqual(classifyRestProbe(401, { code: '42501', message: 'permission denied for table organizations' }), { ok: true })
  assert.deepEqual(classifyRestProbe(403, { code: '42501' }), { ok: true })
})
test('database probe: bad or missing key, PostgREST-only errors, gateway and server errors are NOT reachability', () => {
  assert.deepEqual(classifyRestProbe(401, { message: 'Invalid API key' }), { ok: false, reason: 'bad_key', upstreamStatus: 401 })
  assert.deepEqual(classifyRestProbe(401, { message: 'No API key found in request' }), { ok: false, reason: 'bad_key', upstreamStatus: 401 })
  assert.deepEqual(classifyRestProbe(401, { message: 'Secret API key required' }), { ok: false, reason: 'bad_key', upstreamStatus: 401 })
  assert.equal(classifyRestProbe(401, { code: 'PGRST301' }).ok, false)
  for (const s of [404, 500, 502, 503, 504]) assert.equal(classifyRestProbe(s, { code: '42501' }).ok, false, String(s))
  assert.equal(classifyRestProbe(401, null).ok, false)
  assert.equal(classifyRestProbe(401, 'text').ok, false)
})
test('auth probe and failures', () => {
  assert.deepEqual(classifyAuthProbe(200), { ok: true })
  assert.equal(classifyAuthProbe(401).reason, 'bad_key')
  assert.equal(classifyAuthProbe(503).reason, 'upstream_error')
  const abort = new Error('x'); abort.name = 'AbortError'
  assert.deepEqual(failureProbe(abort), { ok: false, reason: 'timeout' })
  assert.deepEqual(failureProbe(new TypeError('fetch failed')), { ok: false, reason: 'network_error' })
})
test('health route trims env whitespace, never echoes values, keeps cache and exposes only fixed reason codes', () => {
  const r = read('src/app/api/health/route.ts')
  assert.match(r, /NEXT_PUBLIC_SUPABASE_URL\?\.trim\(\)/)
  assert.match(r, /NEXT_PUBLIC_SUPABASE_ANON_KEY\?\.trim\(\)/)
  assert.match(r, /CACHE_MS/)
  assert.doesNotMatch(code(r), /createAdminClient|SERVICE_ROLE|WORKER_SECRET|console\./)
  assert.doesNotMatch(code(r), /\.\.\.\s*\{\s*url|key\s*[,}]\s*\)/)
})
