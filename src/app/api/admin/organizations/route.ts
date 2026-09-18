import { NextResponse } from 'next/server'
import { createClient } from '@/utils/supabase/server'
import { createAdminClient } from '@/lib/supabaseAdmin'

export async function POST(request: Request) {
  const caller = await createClient()
  const { data: { user } } = await caller.auth.getUser()
  if (!user) return NextResponse.json({ error: 'unauthorized' }, { status: 401 })

  const { data: callerMemberships } = await caller
    .from('organization_memberships')
    .select('role')
    .eq('status','active')
    .eq('role','admin')
    .limit(1)

  if (!callerMemberships?.length) {
    return NextResponse.json({ error: 'admin_membership_required' }, { status: 403 })
  }

  const body = await request.json()
  const email = String(body.email ?? '').trim().toLowerCase()
  const organizationName = String(body.organizationName ?? '').trim()
  const organizationDocument = String(body.organizationDocument ?? '').trim()
  const fullName = String(body.fullName ?? '').trim()

  if (!email || !organizationName || !organizationDocument) {
    return NextResponse.json({ error: 'invalid_input' }, { status: 400 })
  }

  const admin = createAdminClient()
  const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    data: fullName ? { full_name: fullName } : undefined
  })
  if (inviteError || !invited.user) {
    return NextResponse.json({ error: 'invite_failed' }, { status: 400 })
  }

  const { data: organizationId, error: bootstrapError } = await admin.rpc('bootstrap_organization_admin', {
    p_user_id: invited.user.id,
    p_organization_name: organizationName,
    p_organization_document: organizationDocument,
    p_plan_type: 'founder'
  })

  if (bootstrapError) {
    // Auth invite cannot participate in the Postgres transaction. Compensate to avoid orphan identity.
    await admin.auth.admin.deleteUser(invited.user.id)
    return NextResponse.json({ error: 'bootstrap_failed' }, { status: 500 })
  }

  return NextResponse.json({ organizationId }, { status: 201 })
}
