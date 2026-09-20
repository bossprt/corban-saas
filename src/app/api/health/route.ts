import { NextResponse } from 'next/server'

// Liveness + database reachability for uptime monitors. Deliberately minimal and unauthenticated: no secrets, no configuration,
// no provider or worker state (that is business readiness and is shown only to signed-in supervisors on /app/integracoes).
export const dynamic = 'force-dynamic'

type DatabaseProbe = {
  ok: boolean
  reason?: 'missing_url' | 'missing_key' | 'timeout' | 'network_error' | 'upstream_error'
  upstreamStatus?: number
}

async function databaseReachable(): Promise<DatabaseProbe> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url) return { ok: false, reason: 'missing_url' }
  if (!key) return { ok: false, reason: 'missing_key' }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 2500)
  try {
    const res = await fetch(`${url}/rest/v1/`, {
      headers: { apikey: key },
      signal: controller.signal,
      cache: 'no-store',
    })
    if (res.ok) return { ok: true }
    return { ok: false, reason: 'upstream_error', upstreamStatus: res.status }
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') return { ok: false, reason: 'timeout' }
    return { ok: false, reason: 'network_error' }
  } finally {
    clearTimeout(timer)
  }
}

// A monitor (or an attacker) hammering this endpoint costs at most one upstream probe every 5 seconds per instance.
let cached: { at: number; probe: DatabaseProbe } | null = null
const CACHE_MS = 5000

export async function GET() {
  if (!cached || Date.now() - cached.at > CACHE_MS) {
    cached = { at: Date.now(), probe: await databaseReachable() }
  }

  const database = cached.probe.ok ? 'ok' : 'unavailable'
  return NextResponse.json(
    {
      status: database === 'ok' ? 'ok' : 'degraded',
      app: 'ok',
      database,
      ...(cached.probe.reason ? { databaseReason: cached.probe.reason } : {}),
      ...(cached.probe.upstreamStatus ? { databaseUpstreamStatus: cached.probe.upstreamStatus } : {}),
    },
    {
      status: database === 'ok' ? 200 : 503,
      headers: { 'Cache-Control': 'no-store' },
    },
  )
}
