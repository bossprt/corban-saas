'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { isUuid } from '@/lib/team'

const back = (code: FeedbackCode, cliente?: string): never =>
  redirect(feedbackUrl(cliente && isUuid(cliente) ? `/app/propostas/nova?cliente=${cliente}` : '/app/propostas/nova', code))

// Direct proposal: before digitization (queue) or already digitized with the ADE. Same bank + ADE opens the existing one.
export async function createDirectProposal(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const text = (k: string) => String(formData.get(k) ?? '').trim()
  const client = text('customer_id')
  const table = text('table_version_id')
  const seller = text('seller_id')
  const stage = text('stage') === 'submitted' ? 'submitted' : 'digitization_queue'
  const ade = text('ade')
  if (!isUuid(client) || !isUuid(table) || (seller && !isUuid(seller))) return back('erro:requisicao_invalida', client)
  const requested = parseMoneyInput(formData.get('requested_amount'))
  const released = parseMoneyInput(formData.get('released_amount'))
  const installment = parseMoneyInput(formData.get('installment_amount'))
  if (requested === 'invalid' || released === 'invalid' || installment === 'invalid') return back('erro:valor_invalido', client)
  if (!requested && !released) return back('erro:valor_invalido', client)
  const termText = text('term')
  const term = termText ? Number.parseInt(termText, 10) : null
  if (termText && (!Number.isInteger(term) || term! < 1 || term! > 420)) return back('erro:prazo_invalido', client)
  if (stage === 'submitted' && !ade) return back('erro:ade_obrigatorio', client)

  const { data, error } = await supabase.rpc('create_direct_proposal', {
    p_org: organization.id, p_customer_id: client, p_table_version_id: table, p_seller_id: seller || null,
    p_requested_amount: requested, p_released_amount: released, p_installment_amount: installment, p_term: term,
    p_ade: ade || null, p_stage: stage,
  })
  if (error) {
    const m = error.message ?? ''
    if (/ade_required/.test(m)) return back('erro:ade_obrigatorio', client)
    if (/invalid_ade/.test(m)) return back('erro:ade_invalido', client)
    if (/invalid_amount|amount_required/.test(m)) return back('erro:valor_invalido', client)
    if (/invalid_term/.test(m)) return back('erro:prazo_invalido', client)
    return back(classifyDbFeedback(error), client)
  }
  const row = (Array.isArray(data) ? data[0] : data) as { proposal_id: string; duplicate: boolean } | null
  if (!row) return back('erro:inesperado', client)
  revalidatePath('/app/propostas')
  redirect(feedbackUrl(`/app/propostas/${row.proposal_id}`, row.duplicate ? 'ok:proposta_ja_existia' : 'ok:proposta_criada'))
}
