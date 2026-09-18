import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'

export async function requireAppContext() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: membership } = await supabase
    .from('organization_memberships')
    .select('organization_id, role, status')
    .eq('user_id', user.id)
    .eq('status', 'active')
    .maybeSingle()

  if (!membership) redirect('/access-pending')

  const { data: organization } = await supabase
    .from('organizations')
    .select('id, name')
    .eq('id', membership.organization_id)
    .single()

  return { supabase, user, membership, organization }
}
