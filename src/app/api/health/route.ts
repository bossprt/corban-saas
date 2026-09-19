import { NextResponse } from 'next/server'

// Liveness + database reachability for uptime monitors. Deliberately minimal and unauthenticated: no secrets, no configuration,
// no provider or worker state (that is business readiness and is shown only to signed-in supervisors on /app/integracoes).
export const dynamic = 'force-dynamic'

async function databaseReachable(): Promise<boolean> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  if (!url || !key) return false
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 2500)
  try {
    const res = await fetch(`${url}/rest/v1/`, { headers: { apikey: key }, signal: controller.signal, cache: 'no-store' })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

// A monitor (or an attacker) hammering this endpoint costs at most one upstream probe every 5 seconds per instance.
let cached: { at: number; ok: boolean } | null = null
const CACHE_MS = 5000

export async function GET() {
  if (!cached || Date.now() - cached.at > CACHE_MS) cached = { at: Date.now(), ok: await databaseReachable() }
  const database = cached.ok ? 'ok' : 'unavailable'
  return NextResponse.json({ status: database === 'ok' ? 'ok' : 'degraded', app: 'ok', database }, { status: database === 'ok' ? 200 : 503, headers: { 'Cache-Control': 'no-store' } })
}
