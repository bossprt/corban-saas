'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

function proposalId(formData: FormData) {
  const id = String(formData.get('proposal_id') ?? '')
  if (!id) throw new Error('Proposta inválida.')
  return id
}

export async function prepareDocuments(formData: FormData) {
  const id = proposalId(formData)
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('prepare_proposal_documents', { p_proposal_id: id })
  if (error) throw new Error('Não foi possível preparar o checklist documental.')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/propostas')
}

export async function sendToDigitization(formData: FormData) {
  const id = proposalId(formData)
  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('send_proposal_to_digitization', { p_proposal_id: id })
  if (error) throw new Error('A proposta não pôde ser enviada para digitação.')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/propostas')
  revalidatePath('/app/operacao')
  revalidatePath('/app')
}

export async function attachDocument(formData: FormData) {
  const id = proposalId(formData)
  const requirementId = String(formData.get('requirement_id') ?? '')
  const documentId = String(formData.get('document_id') ?? '')
  if (!requirementId || !documentId) throw new Error('Requisito ou documento inválido.')

  const { supabase, user, membership } = await requireAppContext()
  const [{ data: requirement }, { data: document }] = await Promise.all([
    supabase.from('proposal_document_requirements')
      .select('id,document_type_id,status').eq('id', requirementId).eq('proposal_id', id).maybeSingle(),
    supabase.from('customer_documents')
      .select('id,document_type_id,status').eq('id', documentId).eq('status', 'active').maybeSingle(),
  ])

  if (!requirement || !document || requirement.document_type_id !== document.document_type_id) {
    throw new Error('Documento incompatível com o requisito.')
  }

  const { error: linkError } = await supabase.from('proposal_document_links').insert({
    organization_id: membership.organization_id,
    requirement_id: requirement.id,
    customer_document_id: document.id,
    linked_by: user.id,
  })
  if (linkError && linkError.code !== '23505') throw new Error('Não foi possível vincular o documento.')

  const { error: statusError } = await supabase.from('proposal_document_requirements')
    .update({ status: 'attached' }).eq('id', requirement.id)
  if (statusError) throw new Error('Documento vinculado, mas o requisito não pôde ser atualizado.')

  revalidatePath(`/app/propostas/${id}`)
}

export async function validateRequirement(formData: FormData) {
  const id = proposalId(formData)
  const requirementId = String(formData.get('requirement_id') ?? '')
  if (!requirementId) throw new Error('Requisito inválido.')
  const { supabase, membership } = await requireAppContext()
  if (!['admin','manager','supervisor'].includes(membership.role)) {
    throw new Error('Seu perfil não pode validar documentos.')
  }

  const { error } = await supabase.from('proposal_document_requirements')
    .update({ status: 'validated' }).eq('id', requirementId).eq('proposal_id', id)
  if (error) throw new Error('Não foi possível validar o requisito.')

  revalidatePath(`/app/propostas/${id}`)
}


export async function publishExpectedCommission(formData: FormData) {
  const id = proposalId(formData)
  const { supabase, membership } = await requireAppContext()
  if (!['admin','manager','supervisor'].includes(membership.role)) throw new Error('Seu perfil não pode publicar comissão esperada.')
  const { error } = await supabase.rpc('publish_expected_commission', { p_proposal_id: id })
  if (error) throw new Error('Não foi possível publicar a comissão esperada. Verifique snapshot e regras comerciais publicadas.')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/financeiro')
}


export async function refreshFinancialReconciliation(formData: FormData) {
  const id = proposalId(formData)
  const component = String(formData.get('component_type') ?? '') || null
  const { supabase, membership } = await requireAppContext()
  if (!['admin','manager','supervisor'].includes(membership.role)) throw new Error('Seu perfil não pode reconciliar fatos financeiros.')
  const { error } = await supabase.rpc('refresh_financial_reconciliation', { p_proposal_id: id, p_component_type: component })
  if (error) throw new Error('Não foi possível atualizar a reconciliação financeira.')
  revalidatePath(`/app/propostas/${id}`)
  revalidatePath('/app/financeiro')
}
