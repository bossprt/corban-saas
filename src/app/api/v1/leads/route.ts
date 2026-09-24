import { NextResponse } from 'next/server'
import { createAdminClient } from '@/lib/supabaseAdmin'

// Public API v1: create a lead. Authentication, company, scope, modules and rate limit are decided by the database
// (public.api_ingest_lead) from the API key alone; this route only moves bytes. Nothing from the request is logged.
export const dynamic = 'force-dynamic'

const MAX_BYTES = 16_000
const STATUS: Record<string, number> = {
  invalid_api_key: 401,
  insufficient_scope: 403,
  module_disabled: 403,
  rate_limited: 429,
  invalid_full_name: 422,
  phone_or_email_required: 422,
  invalid_email: 422,
  invalid_cpf: 422,
  invalid_external_ref: 422,
  invalid_metadata: 422,
}

const fail = (error: string, status: number) => NextResponse.json({ error }, { status, headers: { 'Cache-Control': 'no-store' } })

export async function POST(request: Request) {
  const auth = request.headers.get('authorization') ?? ''
  const key = /^Bearer\s+(ck_live_[A-Za-z0-9_-]{20,80})$/.exec(auth)?.[1]
  if (!key) return fail('invalid_api_key', 401)
  if (!(request.headers.get('content-type') ?? '').includes('application/json')) return fail('json_required', 415)

  const raw = await request.text()
  if (raw.length > MAX_BYTES) return fail('payload_too_large', 413)
  let payload: unknown
  try {
    payload = JSON.parse(raw)
  } catch {
    return fail('invalid_json', 400)
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return fail('invalid_json', 400)

  const { data, error } = await createAdminClient().rpc('api_ingest_lead', { p_key: key, p_payload: payload })
  if (error || !data || typeof data !== 'object') return fail('unavailable', 503)
  const result = data as { error?: string; id?: string; status?: string; duplicate?: boolean; matched_client?: boolean }
  if (result.error) return fail(result.error, STATUS[result.error] ?? 400)
  return NextResponse.json(
    { id: result.id, status: result.status, duplicate: !!result.duplicate, matched_client: !!result.matched_client },
    { status: result.duplicate ? 200 : 201, headers: { 'Cache-Control': 'no-store' } },
  )
}
