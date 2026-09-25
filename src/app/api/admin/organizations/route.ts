import { NextResponse } from 'next/server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { digitsOnly, isValidCnpj, sameOrganizationName } from '@/lib/platform'

// Platform bootstrap: creates ONE organization and its first administrator. Platform administrators only.
// Safety: valid CNPJ (stored digits-only, unique in the database), similar-name guard (Smart Promotora / SMART PROMOTORA LTDA), the tenant id is generated
// by the database inside bootstrap_organization_admin (never taken from the request), and the action is written to platform_admin_audit_events by that function.
export async function POST(request: Request) {
  const gate = await requirePlatformAdmin()
  if (!gate.ok) return NextResponse.json({ error: gate.status === 401 ? 'unauthorized' : 'platform_admin_required' }, { status: gate.status })

  let body: Record<string, unknown>
  try { body = await request.json() } catch { return NextResponse.json({ error: 'invalid_json' }, { status: 400 }) }
  const email = String(body.email ?? '').trim().toLowerCase()
  const organizationName = String(body.organizationName ?? '').trim()
  const organizationDocument = digitsOnly(String(body.organizationDocument ?? ''))
  const fullName = String(body.fullName ?? '').trim()
  const confirmSimilar = body.confirmSimilarName === true

  if (!email || !email.includes('@') || email.length > 254 || !organizationName || organizationName.length > 200 || fullName.length > 200) {
    return NextResponse.json({ error: 'invalid_input' }, { status: 400 })
  }
  if (!isValidCnpj(organizationDocument)) return NextResponse.json({ error: 'invalid_cnpj' }, { status: 400 })

  const admin = createAdminClient()
  const { data: existing, error: listError } = await admin.from('organizations').select('id,name,document')
  if (listError) return NextResponse.json({ error: 'bootstrap_failed' }, { status: 500 })
  if ((existing ?? []).some(o => digitsOnly(o.document) === organizationDocument)) return NextResponse.json({ error: 'organization_document_exists' }, { status: 409 })
  if (!confirmSimilar && (existing ?? []).some(o => sameOrganizationName(o.name, organizationName))) return NextResponse.json({ error: 'similar_organization_exists' }, { status: 409 })

  const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, { data: fullName ? { full_name: fullName } : undefined })
  if (inviteError || !invited.user) return NextResponse.json({ error: 'invite_failed' }, { status: 400 })

  const { data: organizationId, error: bootstrapError } = await admin.rpc('bootstrap_organization_admin', {
    p_platform_actor_user_id: gate.userId, p_user_id: invited.user.id, p_organization_name: organizationName, p_organization_document: organizationDocument, p_plan_type: 'founder',
  })
  if (bootstrapError) {
    // The Auth invite cannot join the Postgres transaction: compensate so no orphan identity is left behind (the user was created by THIS invite).
    await admin.auth.admin.deleteUser(invited.user.id)
    return NextResponse.json({ error: 'bootstrap_failed' }, { status: 500 })
  }
  return NextResponse.json({ organizationId }, { status: 201 })
}
