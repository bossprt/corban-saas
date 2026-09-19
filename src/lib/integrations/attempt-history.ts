// Operator view of the immutable per-attempt diagnostics (integration_run_artifacts, kind 'diagnostic'). Pure and defensive:
// the database already stores only fixed-shape diagnostics and replaces secret-looking text, but the UI treats every field as UNTRUSTED
// and shows a whitelist only. Nothing here ever returns raw payloads, request metadata or provider responses.

export type DiagnosticRow = { created_at: string; payload: unknown }
export type AttemptEntry = {
  attempt: number
  label: string
  outcome: 'retry_scheduled' | 'failed_terminal' | 'lease_expired' | 'unknown'
  code: string | null
  message: string | null
  retryable: boolean | null
  at: string | null
}

export const ATTEMPT_OUTCOME_LABEL: Record<AttemptEntry['outcome'], string> = {
  retry_scheduled: 'Falhou; nova tentativa agendada',
  failed_terminal: 'Falhou em definitivo',
  lease_expired: 'Interrompida (processamento não terminou; outra tentativa assumiu)',
  unknown: 'Resultado não reconhecido',
}
export const OMITTED = '[omitido por segurança]'

const CODE_SHAPE = /^[A-Za-z0-9_:.-]{1,80}$/
// Anything that looks like a credential, token, personal identifier or a URL with credentials is replaced, never shown truncated.
const SENSITIVE = [
  /bearer\s+\S+/i, /\beyJ[A-Za-z0-9_-]{10,}/, /(api[_-]?key|secret|token|passw|senha|authorization|cookie|credential)/i,
  /\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/, /[^\s@]+@[^\s@]+\.[^\s@]+/, /\b\d{10,}\b/, /[A-Za-z0-9+/_-]{32,}/, /:\/\/[^/\s]*:[^/\s]*@/,
]

export function safeText(value: unknown, max = 200): string | null {
  if (typeof value !== 'string') return null
  const clean = Array.from(value, c => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? ' ' : c)).join('').replace(/\s+/g, ' ').trim()
  if (!clean) return null
  if (SENSITIVE.some(r => r.test(clean))) return OMITTED
  return clean.length > max ? `${clean.slice(0, max)}…` : clean
}

const OUTCOMES = new Set(['retry_scheduled', 'failed_terminal', 'lease_expired'])

export function buildAttemptHistory(rows: DiagnosticRow[] | null | undefined): AttemptEntry[] {
  const out: AttemptEntry[] = []
  for (const row of rows ?? []) {
    const p = row?.payload
    if (!p || typeof p !== 'object' || Array.isArray(p)) continue
    const o = p as Record<string, unknown>
    const attempt = typeof o.attempt === 'number' && Number.isInteger(o.attempt) && o.attempt >= 0 && o.attempt <= 100 ? o.attempt : null
    if (attempt === null) continue
    const outcome = typeof o.outcome === 'string' && OUTCOMES.has(o.outcome) ? (o.outcome as AttemptEntry['outcome']) : 'unknown'
    const at = typeof o.at === 'string' && !Number.isNaN(Date.parse(o.at)) ? o.at : Number.isNaN(Date.parse(row.created_at)) ? null : row.created_at
    out.push({
      attempt, outcome, label: ATTEMPT_OUTCOME_LABEL[outcome],
      code: typeof o.code === 'string' ? (CODE_SHAPE.test(o.code) && !SENSITIVE.some(r => r.test(o.code as string)) ? o.code : OMITTED) : null,
      message: safeText(o.message),
      retryable: typeof o.retryable === 'boolean' ? o.retryable : null,
      at,
    })
  }
  return out.sort((a, b) => a.attempt - b.attempt || (a.at ?? '').localeCompare(b.at ?? ''))
}

export function groupByRun<T extends { run_id: string }>(rows: T[] | null | undefined): Map<string, T[]> {
  const m = new Map<string, T[]>()
  for (const r of rows ?? []) m.set(r.run_id, [...(m.get(r.run_id) ?? []), r])
  return m
}
