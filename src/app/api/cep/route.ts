import { NextResponse } from 'next/server'
import { createClient } from '@/utils/supabase/server'
import { allowLookup, normalizeCep, parseViaCep, type CepLookup } from '@/lib/cep'

// Authenticated CEP lookup (no key, no secret, no cost): only a signed-in user can use it, so it is not an open proxy. It answers a small fixed shape and never
// forwards the upstream body. Any upstream problem becomes { kind: 'unavailable' } and the form keeps working by hand.
const hits = new Map<string, number[]>()
const json = (body: CepLookup | { kind: 'error' }, status = 200) => NextResponse.json(body, { status, headers: { 'Cache-Control': 'no-store' } })

export async function GET(request: Request) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return json({ kind: 'error' }, 401)
  const cep = normalizeCep(new URL(request.url).searchParams.get('cep'))
  if (!cep) return json({ kind: 'invalid' })
  if (!allowLookup(hits, user.id, Date.now())) return json({ kind: 'unavailable' }, 429)
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), 4000)
  try {
    const res = await fetch(`https://viacep.com.br/ws/${cep}/json/`, { signal: ctl.signal, cache: 'no-store', headers: { Accept: 'application/json' } })
    let body: unknown = null
    try { body = await res.json() } catch { /* not JSON: handled as unavailable */ }
    return json(parseViaCep(res.status, body))
  } catch {
    return json({ kind: 'unavailable' })
  } finally {
    clearTimeout(timer)
  }
}
