'use server'

import { headers } from 'next/headers'
import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'

// The company's administrator accepts the terms in force, on behalf of the company (08/10/2026). The database checks
// the role and the version and records who, when, the IP and browser, and the text's hash.
export async function acceptTerms(formData: FormData) {
  const { supabase, organization } = await requireAppContext({ allowPendingTerms: true })
  const version = String(formData.get('version_id') ?? '')
  if (!isUuid(version) || formData.get('agree') !== 'on') redirect('/termos?erro=marque')
  const h = await headers()
  const ip = (h.get('x-forwarded-for') ?? '').split(',')[0].trim() || h.get('x-real-ip') || null
  const { error } = await supabase.rpc('accept_terms', { p_org: organization.id, p_version_id: version, p_ip: ip, p_user_agent: h.get('user-agent') })
  if (error) redirect(/terms_version_not_current/.test(error.message ?? '') ? '/termos?erro=versao' : '/termos?erro=falhou')
  redirect('/app')
}
