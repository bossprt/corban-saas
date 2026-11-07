'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { feedbackUrl } from '@/lib/feedback'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'

// Revoking a key answers with a message (06/11/2026): before, a failure left the screen silent. Kept apart from the
// key creation, which never redirects (the new key must never reach a URL).
export async function revokeApiKey(formData: FormData) {
  const { supabase, membership } = await requireAppContext()
  const id = String(formData.get('key_id') ?? '')
  if (membership.role !== 'admin') return redirect(feedbackUrl('/app/configuracao/api', 'erro:sem_permissao'))
  if (!isUuid(id)) return redirect(feedbackUrl('/app/configuracao/api', 'erro:requisicao_invalida'))
  const { error } = await supabase.rpc('revoke_api_key', { p_key_id: id })
  revalidatePath('/app/configuracao/api')
  return redirect(feedbackUrl('/app/configuracao/api', error ? 'erro:chave_revogar' : 'ok:chave_revogada'))
}
