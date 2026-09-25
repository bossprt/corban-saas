import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { ACTIVE_ORG_COOKIE,resolveActiveMembership,scopeToOrganization,type MembershipRow } from '@/lib/tenant'
import { isScope, type Access, type Tier } from '@/lib/access'

export async function requireAppContext() {
  const rawClient = await createClient()
  const { data: { user }, error: userError } = await rawClient.auth.getUser()
  if (userError || !user) redirect('/login')

  const { data: rows, error: membershipError } = await rawClient
    .from('organization_memberships')
    .select('organization_id, role')
    .eq('user_id', user.id)
    .eq('status', 'active')

  if (membershipError) redirect('/access-pending')

  const cookieStore = await cookies()
  const resolution = resolveActiveMembership((rows ?? []) as MembershipRow[], cookieStore.get(ACTIVE_ORG_COOKIE)?.value)

  if (resolution.kind === 'none') {
    const { data: platformAdmin } = await createAdminClient()
      .from('platform_administrators')
      .select('user_id')
      .eq('user_id', user.id)
      .eq('status', 'active')
      .maybeSingle()
    if (platformAdmin) redirect('/platform')
    redirect('/access-pending')
  }

  if (resolution.kind === 'choose') redirect('/organizacao')

  const membership = { organization_id: resolution.membership.organization_id, role: resolution.membership.role, status: 'active' }
  const { data: organization, error: organizationError } = await rawClient
    .from('organizations')
    .select('id, name')
    .eq('id', membership.organization_id)
    .single()

  if (organizationError || !organization) redirect('/access-pending')

  const supabase = scopeToOrganization(rawClient, organization.id)
  // Role, scope and permissions of the caller in this company. A failure leaves `access` null, which denies every permission.
  const { data: accessRows } = await rawClient.rpc('my_access', { p_org: organization.id })
  const a = Array.isArray(accessRows) ? accessRows[0] : null
  const access: Access | null = a && isScope(a.scope)
    ? { roleId: a.role_id, roleKey: a.role_key, roleName: a.role_name, tier: a.tier as Tier, scope: a.scope, permissions: new Set<string>(a.permissions ?? []) }
    : null
  // Modules switched on for this company (plan). A failure leaves the set empty, which hides every module.
  const { data: moduleRows } = await rawClient.rpc('my_modules', { p_org: organization.id })
  const modules = new Set<string>(Array.isArray(moduleRows) ? (moduleRows as string[]) : [])
  return { supabase, user, membership, organization, access, modules, membershipCount: (rows ?? []).length }
}
