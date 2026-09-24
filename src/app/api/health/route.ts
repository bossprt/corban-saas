import { NextResponse } from 'next/server'
import { classifyAuthProbe, classifyRestProbe, failureProbe, type Probe } from '@/lib/health'

// Liveness + Supabase reachability for uptime monitors. Deliberately minimal and unauthenticated: no secrets, no configuration values, no provider or
// worker state. Probe semantics: see src/lib/health.ts.
export const dynamic = 'force-dynamic'

async function probes(): Promise<{ database: Probe; auth: Probe }> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim()
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim()
  if (!url) return { database: { ok: false, reason: 'missing_url' }, auth: { ok: false, reason: 'missing_url' } }
  if (!key) return { database: { ok: false, reason: 'missing_key' }, auth: { ok: false, reason: 'missing_key' } }
  const base = url.replace(/\/+$/, '')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 2500)
  const init = { headers: { apikey: key }, signal: controller.signal, cache: 'no-store' as const }
  try {
    const [rest, auth] = await Promise.all([
      // A table the anon role cannot read: the DATABASE answers 42501 (or 200 with RLS-filtered rows). Reads nothing.
      fetch(`${base}/rest/v1/organizations?select=id&limit=1`, init).then(async r => classifyRestProbe(r.status, await r.json().catch(() => null)), failureProbe),
      fetch(`${base}/auth/v1/health`, init).then(r => classifyAuthProbe(r.status), failureProbe),
    ])
    return { database: rest, auth }
  } finally {
    clearTimeout(timer)
  }
}

// A monitor (or an attacker) hammering this endpoint costs at most one pair of upstream probes every 5 seconds per instance.
let cached: { at: number; result: Awaited<ReturnType<typeof probes>> } | null = null
const CACHE_MS = 5000

export async function GET() {
  if (!cached || Date.now() - cached.at > CACHE_MS) cached = { at: Date.now(), result: await probes() }
  const { database, auth } = cached.result
  const healthy = database.ok && auth.ok
  return NextResponse.json(
    {
      status: healthy ? 'ok' : 'degraded',
      app: 'ok',
      database: database.ok ? 'ok' : 'unavailable',
      auth: auth.ok ? 'ok' : 'unavailable',
      ...(database.reason ? { databaseReason: database.reason } : {}),
      ...(auth.reason ? { authReason: auth.reason } : {}),
    },
    { status: healthy ? 200 : 503, headers: { 'Cache-Control': 'no-store' } },
  )
}
