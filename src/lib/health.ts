// Health probe classification (pure). Supabase changed the semantics of the REST root: with a publishable/anon key `GET /rest/v1/` answers 401
// "Secret API key required" (the OpenAPI document is secret-key only), so it can never prove reachability with the keys this app is allowed to hold.
// What DOES prove it, without any secret and without weakening RLS:
//   * Auth:      GET /auth/v1/health with the public apikey -> 200.
//   * Database:  a real PostgREST query on a table the anon role cannot read. PostgREST forwards it to Postgres, which answers 42501 (permission denied):
//                an error CODE produced by the database itself. 200 (rows filtered by RLS) is equally fine. Anything else (timeout, 5xx, gateway errors,
//                401 without a Postgres code such as a bad key) is NOT reachability.
export type ProbeReason = 'missing_url' | 'missing_key' | 'timeout' | 'network_error' | 'upstream_error' | 'bad_key'
export type Probe = { ok: boolean; reason?: ProbeReason; upstreamStatus?: number }

export const classifyAuthProbe = (status: number): Probe => (status === 200 ? { ok: true } : status === 401 || status === 403 ? { ok: false, reason: 'bad_key', upstreamStatus: status } : { ok: false, reason: 'upstream_error', upstreamStatus: status })

export function classifyRestProbe(status: number, body: unknown): Probe {
  if (status === 200 || status === 206) return { ok: true }
  const code = body && typeof body === 'object' && typeof (body as { code?: unknown }).code === 'string' ? (body as { code: string }).code : ''
  // Postgres SQLSTATE (5 chars, e.g. 42501) surfaced by PostgREST proves the database answered. PGRST* codes are PostgREST's own (not the database).
  if ((status === 401 || status === 403) && /^[0-9A-Z]{5}$/.test(code) && !code.startsWith('PGRST')) return { ok: true }
  if (status === 401 || status === 403) return { ok: false, reason: 'bad_key', upstreamStatus: status }
  return { ok: false, reason: 'upstream_error', upstreamStatus: status }
}

export function failureProbe(error: unknown): Probe {
  return error instanceof Error && error.name === 'AbortError' ? { ok: false, reason: 'timeout' } : { ok: false, reason: 'network_error' }
}
