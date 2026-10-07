import 'server-only'
import { BEVICRED_URL, classifyTokenResponse, type BevicredProbe } from '@/lib/bevicred'

// Asks Bevicred for a token (POST, Basic auth with partner code and API key, form field modulo=AGENTE) and reports only
// whether it worked. The token is discarded: phase 1 reads nothing.
export async function probeBevicred(): Promise<BevicredProbe> {
  const partner = process.env.BEVICRED_PARTNER_CODE?.trim()
  const key = process.env.BEVICRED_API_KEY?.trim()
  if (!partner || !key || partner === 'PREENCHER' || key === 'PREENCHER') return { ok: false, reason: 'not_configured' }
  const body = new FormData()
  body.set('modulo', 'AGENTE')
  const started = Date.now()
  try {
    const res = await fetch(BEVICRED_URL, {
      method: 'POST', body, cache: 'no-store', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Basic ${Buffer.from(`${partner}:${key}`).toString('base64')}`, Accept: 'application/json' },
    })
    return classifyTokenResponse(res.status, await res.text(), Date.now() - started)
  } catch (e) {
    const ms = Date.now() - started
    return e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError') ? { ok: false, reason: 'timeout', ms } : { ok: false, reason: 'network', ms }
  }
}
