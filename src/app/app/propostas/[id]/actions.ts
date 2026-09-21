'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const idOf = (formData: FormData) => { const id = String(formData.get('proposal_id') ?? ''); return UUID.test(id) ? id : null }
const back = (id: string | null, code: FeedbackCode): never => redirect(feedbackUrl(id ? `/app/propostas/${id}` : '/app/propostas', code))
// Kept for the supervisor-only financial actions below (they still throw; the error boundary shows a sanitized message).
function proposalId(formData: FormData) {
  const id = String(formData.get('proposal_id') ?? '')
  if (!id) throw new Error('Proposta inválida.')
  return id
}

export async function assignProposalSeller(formData: FormData) {
  const id = idOf(formData)
  const sellerRaw = String(formData.get('seller_id') ?? '')
  const sellerId = sellerRaw === '' ? null : sellerRaw
  if (!id || (sellerId !== null && !UUID.test(sellerId))) return back(id, 'erro:requisicao_invalida')

  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return back(id, 'erro:sem_permissao')

  const { error } = await supabase.rpc('assign_proposal_seller', {
    p_proposal_id: id,
    p_seller_id: sellerId,
  })
  if (error) {
    const msg = error.message ?? ''
    if (/forbidden|not_authorized/.test(msg)) return back(id, 'erro:sem_permissao')
    if (/proposal_commercial_route_already_frozen|proposal_seller_is_frozen/.test(msg)) return back(id, 'erro:requisicao_invalida')
    return back(id, 'erro:requisicao_invalida')
  }

  revalidatePath(`/app/propostas/${id}`)
  return back(id, 'ok:vendedor_atualizado')
}

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

export async function publishExpectedCommission(formData: FormData) {
  const id = idOf(formData)
  if (!id) return back(null, 'erro:requisicao_invalida')
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role,'supervisor')) return back(id, 'erro:sem_permissao')
  const { error } = await supabase.rpc('publish_expected_commission', { p_proposal_id: id })
  if (error) return back(id, /forbidden|not_authorized/.test(error.message ?? '') ? 'erro:sem_permissao' : 'erro:comissao_esperada')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/financeiro')
  return back(id, 'ok:comissao_esperada_publicada')
}


export async function refreshFinancialReconciliation(formData: FormData) {
  const id = proposalId(formData)
  const component = String(formData.get('component_type') ?? '') || null
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role,'supervisor')) throw new Error('Seu perfil não pode reconciliar fatos financeiros.')
  const { error } = await supabase.rpc('refresh_financial_reconciliation', { p_proposal_id: id, p_component_type: component })
  if (error) throw new Error('Não foi possível atualizar a reconciliação financeira.')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/financeiro')
}


export async function freezeCommercialRoute(formData: FormData) {
  const id = idOf(formData)
  const ruleId = String(formData.get('commission_rule_version_id') ?? '')
  const producerRaw = String(formData.get('producer_entity_id') ?? '')
  const producerId = producerRaw === '' ? null : producerRaw
  if (!id || !UUID.test(ruleId) || (producerId !== null && !UUID.test(producerId))) return back(id, 'erro:requisicao_invalida')

  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return back(id, 'erro:sem_permissao')

  const now = new Date().toISOString()
  const { data: rule, error: ruleError } = await supabase
    .from('channel_commission_rule_versions')
    .select('id,channel_id,effective_from,effective_until,status')
    .eq('id', ruleId)
    .eq('status', 'published')
    .maybeSingle()

  if (ruleError || !rule) return back(id, 'erro:rota_comercial')
  if ((rule.effective_from && rule.effective_from > now) || (rule.effective_until && rule.effective_until <= now)) {
    return back(id, 'erro:rota_comercial')
  }

  const { error } = await supabase.rpc('freeze_proposal_commercial_route', {
    p_proposal_id: id,
    p_channel_id: rule.channel_id,
    p_commission_rule_version_id: rule.id,
    p_producer_entity_id: producerId,
  })
  if (error) return back(id, /forbidden|not_authorized/.test(error.message ?? '') ? 'erro:sem_permissao' : 'erro:rota_comercial')

  revalidatePath(`/app/propostas/${id}`)
  return back(id, 'ok:rota_congelada')
}
