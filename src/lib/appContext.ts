import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { ACTIVE_ORG_COOKIE,resolveActiveMembership,scopeToOrganization,type MembershipRow } from '@/lib/tenant'

export async function requireAppContext() {
  const rawClient = await createClient()
  const { data: { user }, error: userError } = await rawClient.auth.getUser()
  if (userError || !user) redirect('/login')

  // ALL active memberships (RLS returns only the caller's own rows). The active tenant is never guessed:
  // one membership -> that one; several -> the explicitly selected one, re-validated here on every request.
  const { data: rows, error: membershipError } = await rawClient
    .from('organization_memberships')
    .select('organization_id, role')
    .eq('user_id', user.id)
    .eq('status', 'active')
  if (membershipError) redirect('/access-pending')

  const cookieStore = await cookies()
  const resolution = resolveActiveMembership((rows ?? []) as MembershipRow[], cookieStore.get(ACTIVE_ORG_COOKIE)?.value)
  if (resolution.kind === 'none') redirect('/access-pending')
  if (resolution.kind === 'choose') redirect('/organizacao')

  const membership = { organization_id: resolution.membership.organization_id, role: resolution.membership.role, status: 'active' }
  const { data: organization, error: organizationError } = await rawClient
    .from('organizations')
    .select('id, name')
    .eq('id', membership.organization_id)
    .single()

  // Fail closed: an authenticated identity is not an application context
  // unless both the active membership and its tenant resolve under RLS.
  if (organizationError || !organization) redirect('/access-pending')

  // RLS admits every organization of the user; the scoped client pins reads/updates/deletes to the ACTIVE one.
  const supabase = scopeToOrganization(rawClient, organization.id)
  return { supabase, user, membership, organization, membershipCount: (rows ?? []).length }
}
