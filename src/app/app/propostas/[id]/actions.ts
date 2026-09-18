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
