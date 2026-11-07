import 'server-only'
import { BEVICRED_URL, classifyTokenResponse, PROBE_TEXT, type BevicredProbe } from '@/lib/bevicred'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { addDaysISO, todaySP } from '@/lib/dates'

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

const post = async (fields: Record<string, string>, auth: string) => {
  const body = new FormData()
  for (const [k, v] of Object.entries(fields)) body.set(k, v)
  const res = await fetch(BEVICRED_URL, {
    method: 'POST', body, cache: 'no-store', signal: AbortSignal.timeout(25000),
    headers: { Authorization: auth, Accept: 'application/json' },
  })
  try { return JSON.parse(await res.text()) as { success?: unknown; message?: unknown; dados?: unknown } } catch { return null }
}

// Runs the calls a few at a time: Bevicred answers one day per call and takes one or two seconds each.
async function inBatches<T, R>(items: T[], size: number, fn: (t: T) => Promise<R>): Promise<R[]> {
  const out: R[] = []
  for (let i = 0; i < items.length; i += size) out.push(...await Promise.all(items.slice(i, i + size).map(fn)))
  return out
}

const dayBr = (back: number) => addDaysISO(todaySP(), -back)

// The company's contracts in Bevicred's "produção sintética" for the last `days` import days (today included), from
// every credential of the company. Read only. A credential that fails is reported by name and the others still count.
// The token lives only inside this call (it is bound to the server's address and never leaves the server).
export async function fetchBevicredProduction(org: string, days: number): Promise<{ rows: { credential: string; row: Record<string, unknown> }[]; errors: string[]; credentials: number }> {
  const admin = createAdminClient()
  const credentials = await listBevicredCredentials(org)
  const rows: { credential: string; row: Record<string, unknown> }[] = []
  const errors: string[] = []
  for (const c of credentials) {
    const { data } = await admin.rpc('bevicred_credential_secret', { p_org: org, p_id: c.id })
    const secret = data as { partner?: unknown; key?: unknown } | null
    if (typeof secret?.partner !== 'string' || typeof secret?.key !== 'string') { errors.push(`${c.label}: credencial ilegível`); continue }
    const auth = `Basic ${Buffer.from(`${secret.partner}:${secret.key}`).toString('base64')}`
    try {
      const tok = await post({ modulo: 'AGENTE' }, auth)
      const token = tok && (tok.success === true || tok.success === 'true') && typeof tok.dados === 'string' ? tok.dados : null
      if (!token) { errors.push(`${c.label}: a Bevicred recusou o acesso`); continue }
      const answers = await inBatches(Array.from({ length: days }, (_, i) => dayBr(i)), 8,
        d => post({ modulo: 'AGENTE', token, assunto: 'PRODUCAOSINTETICO', data: d }, auth).catch(() => null))
      const failed = answers.filter(a => !a || (a.dados !== null && a.dados !== undefined && !Array.isArray(a.dados) && typeof a.dados !== 'object')).length
      for (const a of answers) if (Array.isArray(a?.dados)) for (const row of a.dados) if (row && typeof row === 'object') rows.push({ credential: c.label, row: row as Record<string, unknown> })
      if (failed) errors.push(`${c.label}: ${failed} dia(s) sem resposta da Bevicred`)
    } catch { errors.push(`${c.label}: não foi possível falar com a Bevicred`) }
  }
  return { rows, errors, credentials: credentials.length }
}

export type BevicredLink = { kind: 'table' | 'seller'; external_key: string; external_label: string; target: string }

// What the contract import remembers for the company, with the Corban table or seller name.
export async function listBevicredLinks(org: string): Promise<BevicredLink[]> {
  const admin = createAdminClient()
  const { data } = await admin.from('bevicred_links').select('kind,external_key,external_label,target_id').eq('organization_id', org).order('external_label')
  const rows = (data ?? []) as { kind: 'table' | 'seller'; external_key: string; external_label: string; target_id: string }[]
  const ids = (k: string) => rows.filter(r => r.kind === k).map(r => r.target_id)
  const [{ data: tables }, { data: sellers }] = await Promise.all([
    ids('table').length ? admin.from('product_tables').select('id,name').eq('organization_id', org).in('id', ids('table')) : Promise.resolve({ data: [] }),
    ids('seller').length ? admin.from('commercial_sellers').select('id,name').eq('organization_id', org).in('id', ids('seller')) : Promise.resolve({ data: [] }),
  ])
  const name = new Map([...(tables ?? []), ...(sellers ?? [])].map(x => [(x as { id: string }).id, (x as { name: string }).name]))
  return rows.map(r => ({ kind: r.kind, external_key: r.external_key, external_label: r.external_label, target: name.get(r.target_id) ?? '(removido)' }))
}
