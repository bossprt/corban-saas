'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

const STATES = ['digitizing', 'submitted', 'pending_external', 'approved', 'rejected', 'cancelled', 'paid'] as const

// Moves a proposal in the pipeline through the governed RPC; the database checks permission, scope and the transition.
export async function movePipeline(formData: FormData) {
  const { supabase } = await requireAppContext()
  const proposal = String(formData.get('proposal_id') ?? '')
  const caseId = String(formData.get('case_id') ?? '')
  const to = String(formData.get('to_state') ?? '')
  const note = String(formData.get('note') ?? '').trim()
  const due = String(formData.get('pendency_due') ?? '')
  const back = (code: FeedbackCode): never => redirect(feedbackUrl(`/app/propostas/${proposal}`, code))
  if (!isUuid(proposal) || !isUuid(caseId) || !(STATES as readonly string[]).includes(to)) return back('erro:requisicao_invalida')
  if ((to === 'paid' || to === 'pending_external') && note.length < 3) return back('erro:nota_obrigatoria')
  // The due date comes from a date input (YYYY-MM-DD) and means the end of that day in Brazil.
  const dueAt = to === 'pending_external' && /^\d{4}-\d{2}-\d{2}$/.test(due) ? `${due}T23:59:59-03:00` : null
  if (to === 'pending_external' && !dueAt) return back('erro:prazo_pendencia')
  // Part C3: the day the contract was paid to the client (not in the future).
  const paidOn = String(formData.get('paid_on') ?? '')
  if (to === 'paid' && !/^\d{4}-\d{2}-\d{2}$/.test(paidOn)) return back('erro:pago_data')

  const { error } = await supabase.rpc('move_operational_case', { p_case_id: caseId, p_to_state: to, p_note: note || null, p_pendency_due_at: dueAt, p_paid_on: to === 'paid' ? paidOn : null })
  if (error) {
    const m = error.message ?? ''
    if (/note_required/.test(m)) return back('erro:nota_obrigatoria')
    if (/pendency_due_required/.test(m)) return back('erro:prazo_pendencia')
    if (/invalid_paid_on/.test(m)) return back('erro:pago_data')
    if (/invalid_operational_state_transition|paid_requires/.test(m)) return back('erro:movimento_invalido')
    return back(classifyDbFeedback(error))
  }
  revalidatePath(`/app/propostas/${proposal}`)
  revalidatePath('/app/propostas')
  return back('ok:esteira_movida')
}
