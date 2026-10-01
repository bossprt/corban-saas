'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, type FeedbackCode } from '@/lib/feedback'
import { isUuid } from '@/lib/team'

const DAY = /^\d{4}-\d{2}-\d{2}$/

// Moves a proposal to any of the company's stages (Kanban, table, contract page). The database checks permission,
// scope and the one money lock (a paid contract with money does not leave "Paga"); every move goes to the history.
export async function moveToStage(input: { caseId: string; stageId: string; note?: string; pendencyDue?: string; paidOn?: string; proposalId?: string }): Promise<FeedbackCode> {
  const { supabase } = await requireAppContext()
  const note = String(input.note ?? '').trim()
  const due = String(input.pendencyDue ?? '')
  const paidOn = String(input.paidOn ?? '')
  if (!isUuid(input.caseId) || !isUuid(input.stageId) || note.length > 500 || (due && !DAY.test(due)) || (paidOn && !DAY.test(paidOn))) return 'erro:requisicao_invalida'

  const { error } = await supabase.rpc('move_case_to_stage', {
    p_case_id: input.caseId, p_stage_id: input.stageId, p_note: note || null,
    // A due date means the end of that day in Brazil.
    p_pendency_due_at: due ? `${due}T23:59:59-03:00` : null, p_paid_on: paidOn || null,
  })
  if (error) {
    const m = error.message ?? ''
    if (/invalid_paid_on/.test(m)) return 'erro:pago_data'
    if (/leaving_paid_requires_manager/.test(m)) return 'erro:sair_de_paga_gestor'
    if (/paid_contract_has_money/.test(m)) return 'erro:paga_com_dinheiro'
    if (/target_operational_stage_not_configured|invalid_note/.test(m)) return 'erro:requisicao_invalida'
    return classifyDbFeedback(error)
  }
  revalidatePath('/app/propostas')
  if (input.proposalId && isUuid(input.proposalId)) revalidatePath(`/app/propostas/${input.proposalId}`)
  return 'ok:esteira_movida'
}
