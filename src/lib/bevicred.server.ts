import 'server-only'
import { BEVICRED_URL, classifyTokenResponse, PROBE_TEXT, type BevicredProbe } from '@/lib/bevicred'
import { createAdminClient } from '@/lib/supabaseAdmin'

export type BevicredCredential = {
  id: string; label: string; partner_hint: string
  last_test_at: string | null; last_test_ok: boolean | null; last_test_message: string | null
}

// The company's credentials, without the secret. The caller has already checked the user is the company's administrator.
export async function listBevicredCredentials(org: string): Promise<BevicredCredential[]> {
  const { data, error } = await createAdminClient().from('bevicred_credentials')
    .select('id, label, partner_hint, last_test_at, last_test_ok, last_test_message').eq('organization_id', org).order('created_at')
  if (error) throw new Error('bevicred_credentials_unavailable')
  return data ?? []
}

// Asks Bevicred for a token (POST, Basic auth with partner code and API key, form field modulo=AGENTE) and reports only
// whether it worked. The token is discarded.
async function probe(partner: string, key: string): Promise<BevicredProbe> {
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

// Tests one credential of the company with its secret from Vault and records the result (shown on screen).
export async function testBevicredCredential(org: string, id: string): Promise<{ ok: boolean; message: string }> {
  const admin = createAdminClient()
  const { data } = await admin.rpc('bevicred_credential_secret', { p_org: org, p_id: id })
  const secret = data as { partner?: unknown; key?: unknown } | null
  const r: BevicredProbe = typeof secret?.partner === 'string' && typeof secret?.key === 'string'
    ? await probe(secret.partner, secret.key) : { ok: false, reason: 'not_configured' }
  const message = r.ok ? `Conectou (${r.ms} ms).` : `${PROBE_TEXT[r.reason]}${r.detail ? ` Resposta: ${r.detail}.` : ''}`
  await admin.rpc('bevicred_record_test', { p_org: org, p_id: id, p_ok: r.ok, p_message: message })
  return { ok: r.ok, message }
}
