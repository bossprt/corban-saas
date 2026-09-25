'use server'

import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'
import { createClient } from '@/utils/supabase/server'
import { ACTIVE_ORG_COOKIE } from '@/lib/tenant'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// The chosen organization is only stored after the database confirms an ACTIVE membership for THIS user in it.
// The cookie is a preference, not an authorization: requireAppContext re-validates it against memberships on each request.
export async function selectOrganization(formData: FormData) {
  const organizationId = String(formData.get('organization_id') ?? '')
  if (!UUID.test(organizationId)) redirect('/organizacao?erro=invalid')
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')
  const { data } = await supabase.from('organization_memberships').select('organization_id').eq('user_id', user.id).eq('status', 'active').eq('organization_id', organizationId).maybeSingle()
  if (!data) redirect('/organizacao?erro=forbidden')
  const store = await cookies()
  store.set(ACTIVE_ORG_COOKIE, organizationId, { httpOnly: true, sameSite: 'lax', secure: process.env.NODE_ENV === 'production', path: '/', maxAge: 60 * 60 * 24 * 30 })
  redirect('/app')
}
