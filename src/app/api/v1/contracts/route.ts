import { NextResponse } from 'next/server'
import { createAdminClient } from '@/lib/supabaseAdmin'

// Public API v1: create or update one contract from another system (first user: NASP). Authentication, company, scope,
// modules, rate limit and every rule are decided by the database (public.api_ingest_contract) from the API key alone;
// this route only moves bytes. The body goes to the database as text, so money keeps its exact decimal value.
// Nothing from the request is logged (it carries CPF and personal data).
export const dynamic = 'force-dynamic'

const MAX_BYTES = 32_000
const STATUS: Record<string, number> = {
  invalid_api_key: 401,
  insufficient_scope: 403,
  module_disabled: 403,
  api_key_owner_inactive: 403,
  not_authorized: 403,
  rate_limited: 429,
  invalid_json: 400,
  internal_error: 500,
}

const fail = (error: string, status: number) => NextResponse.json({ error }, { status, headers: { 'Cache-Control': 'no-store' } })

export async function POST(request: Request) {
  const auth = request.headers.get('authorization') ?? ''
  const key = /^Bearer\s+(ck_live_[A-Za-z0-9_-]{20,80})$/.exec(auth)?.[1]
  if (!key) return fail('invalid_api_key', 401)
  if (!(request.headers.get('content-type') ?? '').includes('application/json')) return fail('json_required', 415)

  const raw = await request.text()
  if (raw.length > MAX_BYTES) return fail('payload_too_large', 413)

  const { data, error } = await createAdminClient().rpc('api_ingest_contract', { p_key: key, p_payload: raw })
  if (error || !data || typeof data !== 'object') return fail('unavailable', 503)
  const result = data as { error?: string; id?: string; created?: boolean; duplicate?: boolean; stale?: boolean; stage?: string; warnings?: string[] }
  // Any other code is a refusal of the data (422): the sender fixes it and sends again.
  if (result.error) return fail(result.error, STATUS[result.error] ?? 422)
  return NextResponse.json(
    { id: result.id, created: !!result.created, duplicate: !!result.duplicate, stale: !!result.stale, stage: result.stage, warnings: result.warnings ?? [] },
    { status: result.created ? 201 : 200, headers: { 'Cache-Control': 'no-store' } },
  )
}
