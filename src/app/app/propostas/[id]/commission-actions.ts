'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

// Calculates (or recalculates) the proposal commission in the database and freezes it.
export async function calculateCommission(formData: FormData) {
  const { supabase } = await requireAppContext()
  const proposal = String(formData.get('proposal_id') ?? '')
  const condition = String(formData.get('condition_id') ?? '')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/propostas/${proposal}`, code))
  if (!isUuid(proposal) || (condition && !isUuid(condition))) return back('erro:requisicao_invalida')
  const { error } = await supabase.rpc('calculate_proposal_commission', { p_proposal_id: proposal, p_condition_id: condition || null })
  if (error) {
    const m = error.message ?? ''
    if (/commission_mode_not_configured/.test(m)) return back('erro:comissao_sem_regra')
    if (/condition_not_found/.test(m)) return back('erro:comissao_sem_condicao')
    if (/condition_ambiguous/.test(m)) return back('erro:comissao_ambigua')
    if (/commission_frozen/.test(m)) return back('erro:comissao_congelada')
    if (/payout_exceeds_received/.test(m)) return back('erro:comissao_excede')
    return back(classifyDbFeedback(error))
  }
  revalidatePath(`/app/propostas/${proposal}`)
  return back('ok:comissao_calculada')
}
