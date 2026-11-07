import { cache } from 'react'
import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { ACTIVE_ORG_COOKIE,resolveActiveMembership,scopeToOrganization,type MembershipRow } from '@/lib/tenant'
import { isScope, type Access, type Tier } from '@/lib/access'

// `allowPendingTerms`: only the terms page itself, which must open while the company has not accepted them yet.
// `allowBillingBlocked`: only the monthly fee page, which must open while the company is blocked for an unpaid fee.
// Speed (09/10/2026): one screen calls this from the layout, the page and its parts; React's cache makes it run once
// per request (in a server action it simply runs), and the checks that do not depend on each other run together.
export function requireAppContext(opts?: { allowPendingTerms?: boolean; allowBillingBlocked?: boolean }) {
  return loadAppContext(!!opts?.allowPendingTerms, !!opts?.allowBillingBlocked)
}

// Monthly fee of the company (03/11/2026): `overdue` shows the notice, `blocked` sends every screen to /mensalidade.
export type BillingStatus = { blocked: boolean; overdue: boolean; period?: string; due_on?: string; block_on?: string; amount?: string }

const loadAppContext = cache(async (allowPendingTerms: boolean, allowBillingBlocked: boolean) => {
  const rawClient = await createClient()
  const { data: { user }, error: userError } = await rawClient.auth.getUser()
  if (userError || !user) redirect('/login')
  // Access created by a manager with "choose a new password on the first entry": nothing opens until the person does it.
  if (user.app_metadata?.must_change_password === true) redirect('/auth/definir-senha')

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
  const org = membership.organization_id
  // The company, the terms, the caller's access and the company's modules do not depend on each other: asked together.
  const [{ data: organization, error: organizationError }, termsResult, { data: accessRows }, { data: moduleRows }, { data: billingRow }] = await Promise.all([
    rawClient.from('organizations').select('id, name, brand_color, accent_color, logo_path').eq('id', org).single(),
    allowPendingTerms ? Promise.resolve({ data: false }) : rawClient.rpc('terms_pending', { p_org: org }),
    rawClient.rpc('my_access', { p_org: org }),
    rawClient.rpc('my_modules', { p_org: org }),
    rawClient.rpc('billing_status', { p_org: org }),
  ])

  if (organizationError || !organization) redirect('/access-pending')

  // Terms of use (08/10/2026): while the company has not accepted the version in force, every screen goes to the terms
  // page. A failure to check never blocks (the database refuses nothing on its own because of the terms).
  if (!allowPendingTerms && termsResult.data === true) redirect('/termos')
  // Unpaid fee after the grace days: only the fee page opens. A failure to check never blocks.
  const billing = billingRow && typeof billingRow === 'object' ? billingRow as BillingStatus : null
  if (!allowBillingBlocked && billing?.blocked === true) redirect('/mensalidade')

  const supabase = scopeToOrganization(rawClient, organization.id)
  // Role, scope and permissions of the caller in this company. A failure leaves `access` null, which denies every permission.
  const a = Array.isArray(accessRows) ? accessRows[0] : null
  const access: Access | null = a && isScope(a.scope)
    ? { roleId: a.role_id, roleKey: a.role_key, roleName: a.role_name, tier: a.tier as Tier, scope: a.scope, permissions: new Set<string>(a.permissions ?? []) }
    : null
  // Modules switched on for this company (plan). A failure leaves the set empty, which hides every module.
  const modules = new Set<string>(Array.isArray(moduleRows) ? (moduleRows as string[]) : [])
  return { supabase, user, membership, organization, access, modules, billing, membershipCount: (rows ?? []).length }
})
