'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { classifyTransitionError } from '@/lib/operational'

const allowed = new Set(['digitizing','submitted','pending_external','approved','rejected','cancelled'])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

// The only write path to the esteira is the governed RPC (there is no UPDATE on operational_cases anywhere). Its error is classified,
// not masked: the page shows which rule blocked the move.
export async function transitionOperationalCase(formData: FormData) {
  const caseId = String(formData.get('case_id') ?? '')
  const toState = String(formData.get('to_state') ?? '')
  const rawStatus = String(formData.get('raw_external_status') ?? '').trim() || null
  if (!UUID.test(caseId) || !allowed.has(toState)) redirect('/app/operacao?erro=invalid_transition')

  const { supabase } = await requireAppContext()
  const { error } = await supabase.rpc('transition_operational_case', {
    p_case_id: caseId,
    p_to_state: toState,
    p_raw_external_status: rawStatus,
  })
  if (error) redirect(`/app/operacao?erro=${classifyTransitionError(error.message)}`)

  revalidatePath('/app/operacao')
  revalidatePath('/app/propostas')
  revalidatePath('/app')
  redirect('/app/operacao?ok=1')
}
