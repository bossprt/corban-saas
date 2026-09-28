'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl } from '@/lib/feedback'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// One list of documents for the chosen convênios of a bank. The database publishes a new version per route.
export async function saveBankChecklist(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const bank = String(formData.get('bank_id') ?? '')
  const to = `/app/cadastros/documentos-banco${UUID.test(bank) ? `?banco=${bank}` : ''}`
  const routes = formData.getAll('route_id').map(String).filter(r => UUID.test(r))
  const types = formData.getAll('doc').map(String).filter(t => UUID.test(t))
  if (!routes.length || !types.length || routes.length > 100 || types.length > 30) redirect(feedbackUrl(to, 'erro:checklist_banco_vazio'))
  const items = types.map(id => ({ document_type_id: id, required: formData.get(`req_${id}`) === 'required' }))
  const { error } = await supabase.rpc('save_route_checklist', { p_org: organization.id, p_route_ids: routes, p_items: items })
  if (error) redirect(feedbackUrl(to, classifyDbFeedback(error)))
  revalidatePath('/app/cadastros/documentos-banco')
  redirect(feedbackUrl(to, 'ok:checklist_banco_salvo'))
}
