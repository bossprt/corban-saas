'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

const allowed = new Set(['digitizing','submitted','pending_external','approved','rejected','cancelled'])

export async function transitionOperationalCase(formData: FormData) {
  const caseId = String(formData.get('case_id') ?? '')
  const toState = String(formData.get('to_state') ?? '')
  const rawStatus = String(formData.get('raw_external_status') ?? '').trim() || null
  if (!caseId || !allowed.has(toState)) throw new Error('Transição operacional inválida.')

  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('transition_operational_case', {
    p_case_id: caseId,
    p_to_state: toState,
    p_raw_external_status: rawStatus,
  })
  if (error) throw new Error('A transição foi bloqueada pelas regras operacionais.')

  revalidatePath('/app/operacao')
  revalidatePath('/app/propostas')
  revalidatePath('/app')
}
