import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'

export async function requireAppContext() {
  const supabase = await createClient()
  const { data: { user }, error: userError } = await supabase.auth.getUser()
  if (userError || !user) redirect('/login')

  const { data: membership, error: membershipError } = await supabase
    .from('organization_memberships')
    .select('organization_id, role, status')
    .eq('user_id', user.id)
    .eq('status', 'active')
    .maybeSingle()

  if (membershipError || !membership) redirect('/access-pending')

  const { data: organization, error: organizationError } = await supabase
    .from('organizations')
    .select('id, name')
    .eq('id', membership.organization_id)
    .single()

  // Fail closed: an authenticated identity is not an application context
  // unless both the active membership and its tenant resolve under RLS.
  if (organizationError || !organization) redirect('/access-pending')

  return { supabase, user, membership, organization }
}
