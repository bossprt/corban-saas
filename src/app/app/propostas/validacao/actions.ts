'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

// Validates or refuses a portal proposal. The database checks the permission, the sight of the proposal and that the
// person deciding is not the one who sent it.
export async function decidePortalProposal(formData: FormData) {
  const { supabase } = await requireAppContext()
  const back = (code: FeedbackCode): never => redirect(feedbackUrl('/app/propostas/validacao', code))
  const proposal = String(formData.get('proposal_id') ?? '')
  const approve = formData.get('decision') === 'approve'
  const reason = String(formData.get('reason') ?? '').trim()
  if (!isUuid(proposal)) return back('erro:requisicao_invalida')
  if (!approve && reason.length < 3) return back('erro:portal_motivo')
  const { error } = await supabase.rpc('decide_broker_proposal', { p_proposal: proposal, p_approve: approve, p_reason: approve ? null : reason })
  if (error) {
    const m = error.message ?? ''
    if (/reason_required/.test(m)) return back('erro:portal_motivo')
    if (/submission_already_decided/.test(m)) return back('erro:portal_decidida')
    if (/four_eyes_required/.test(m)) return back('erro:portal_quatro_olhos')
    return back(classifyDbFeedback(error))
  }
  revalidatePath('/app/propostas')
  revalidatePath('/app/propostas/validacao')
  return back(approve ? 'ok:portal_validada' : 'ok:portal_recusada')
}
