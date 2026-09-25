'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const idOf = (formData: FormData) => { const id = String(formData.get('proposal_id') ?? ''); return UUID.test(id) ? id : null }
const back = (id: string | null, code: FeedbackCode): never => redirect(feedbackUrl(id ? `/app/propostas/${id}` : '/app/propostas', code))

export async function prepareDocuments(formData: FormData) {
  const id = idOf(formData)
  if (!id) return back(null, 'erro:requisicao_invalida')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('prepare_proposal_documents', { p_proposal_id: id })
  if (error) return back(id, /forbidden/.test(error.message ?? '') ? 'erro:sem_permissao' : 'erro:checklist')
  revalidatePath(`/app/propostas/${id}`); revalidatePath('/app/propostas')
  return back(id, 'ok:checklist_preparado')
}

export async function sendToDigitization(formData: FormData) {
  const id = idOf(formData)
  if (!id) return back(null, 'erro:requisicao_invalida')
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('send_proposal_to_digitization', { p_proposal_id: id })
  if (error) return back(id, /forbidden/.test(error.message ?? '') ? 'erro:sem_permissao' : 'erro:envio_digitacao')
  revalidatePath(`/app/propostas/${id}`); revalidatePath('/app/propostas'); revalidatePath('/app/operacao'); revalidatePath('/app')
  return back(id, 'ok:enviado_digitacao')
}

export async function attachDocument(formData: FormData) {
  const id = idOf(formData)
  const requirementId = String(formData.get('requirement_id') ?? '')
  const documentId = String(formData.get('document_id') ?? '')
  if (!id || !UUID.test(requirementId) || !UUID.test(documentId)) return back(id, 'erro:requisicao_invalida')

  const { supabase, user, membership } = await requireAppContext()
  const [{ data: requirement }, { data: document }] = await Promise.all([
    supabase.from('proposal_document_requirements').select('id,document_type_id,status').eq('id', requirementId).eq('proposal_id', id).maybeSingle(),
    supabase.from('customer_documents').select('id,document_type_id,status').eq('id', documentId).eq('status', 'active').maybeSingle(),
  ])
  if (!requirement || !document || requirement.document_type_id !== document.document_type_id) return back(id, 'erro:doc_incompativel')

  const { error: linkError } = await supabase.from('proposal_document_links').insert({
    organization_id: membership.organization_id, requirement_id: requirement.id, customer_document_id: document.id, linked_by: user.id,
  })
  if (linkError && linkError.code !== '23505') return back(id, classifyDbFeedback(linkError))
  const { error: statusError } = await supabase.from('proposal_document_requirements').update({ status: 'attached' }).eq('id', requirement.id)
  if (statusError) return back(id, 'erro:requisito')
  revalidatePath(`/app/propostas/${id}`)
  return back(id, 'ok:doc_vinculado')
}

export async function validateRequirement(formData: FormData) {
  const id = idOf(formData)
  const requirementId = String(formData.get('requirement_id') ?? '')
  if (!id || !UUID.test(requirementId)) return back(id, 'erro:requisicao_invalida')
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return back(id, 'erro:sem_permissao')
  const { error } = await supabase.from('proposal_document_requirements').update({ status: 'validated' }).eq('id', requirementId).eq('proposal_id', id)
  if (error) return back(id, 'erro:requisito')
  revalidatePath(`/app/propostas/${id}`)
  return back(id, 'ok:requisito_validado')
}
