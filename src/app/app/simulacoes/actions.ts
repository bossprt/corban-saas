'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifySimulationError } from '@/lib/simulation'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseDecimal } from '@/lib/commercial'
import { isUuid } from '@/lib/team'

const go = (code: FeedbackCode, path = '/app/simulacoes'): never => redirect(feedbackUrl(path, code))

function money(value: FormDataEntryValue | null) {
  const normalized = String(value ?? '').trim().replace(',', '.')
  const parsed = Number(normalized)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null
}

function integer(value: FormDataEntryValue | null) {
  const parsed = Number.parseInt(String(value ?? ''), 10)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null
}

export async function createSimulation(formData: FormData) {
  if (String(formData.get('contract_type_id') ?? '') !== '') return createSimulationForCondition(formData)
  const { supabase } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const tableVersionId = String(formData.get('product_table_version_id') ?? '')
  const requestedAmount = money(formData.get('requested_amount'))
  const term = integer(formData.get('term'))
  if (!customerId || !tableVersionId || requestedAmount === null || requestedAmount <= 0 || !term) return go('erro:requisicao_invalida')

  // The database derives the tenant from the customer, checks that the table version is published for THAT tenant, applies the table rate and
  // coefficient, computes the installment and records the actor. Nothing but the four ids/numbers above comes from the browser.
  const { error } = await supabase.rpc('create_simulation', {
    p_customer_id: customerId, p_table_version_id: tableVersionId, p_requested_amount: requestedAmount, p_term: term,
  })
  if (error) {
    const c = classifySimulationError(error)
    return go(c === 'rpc_unavailable' ? 'erro:indisponivel' : c === 'not_authorized' ? 'erro:sem_permissao' : c === 'unexpected' ? 'erro:inesperado' : (`erro:sim_${c}` as FeedbackCode))
  }
  revalidatePath('/app/simulacoes')
  revalidatePath('/app')
  return go('ok:simulacao_registrada')
}

// Commercial Model V3: the simulation is taken from a commercial CONDITION (Tipo de Contrato + prazo). The amount travels as a decimal string, never a float;
// coefficient/rate come from the condition inside the database and commission is never copied into the simulation.
async function createSimulationForCondition(formData: FormData) {
  const { supabase } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? ''), versionId = String(formData.get('product_table_version_id') ?? ''), typeId = String(formData.get('contract_type_id') ?? '')
  const amount = parseDecimal(formData.get('requested_amount'), { maxInt: 9, scale: 2 })
  const term = integer(formData.get('term'))
  if (!isUuid(customerId) || !isUuid(versionId) || !isUuid(typeId) || amount === null || Number(amount) <= 0 || !term) return go('erro:requisicao_invalida')
  const { error } = await supabase.rpc('create_simulation_for_condition', { p_customer_id: customerId, p_table_version_id: versionId, p_contract_type_id: typeId, p_requested_amount: amount, p_term: term })
  if (error) {
    if (/condition_not_found/.test(error.message ?? '')) return go('erro:sim_condition_not_found')
    const c = classifySimulationError(error)
    return go(c === 'rpc_unavailable' ? 'erro:indisponivel' : c === 'not_authorized' ? 'erro:sem_permissao' : c === 'unexpected' ? 'erro:inesperado' : (`erro:sim_${c}` as FeedbackCode))
  }
  revalidatePath('/app/simulacoes'); revalidatePath('/app')
  return go('ok:simulacao_registrada')
}

export async function createProposalFromSimulation(formData: FormData) {
  const { supabase } = await requireAppContext()
  const simulationId = String(formData.get('simulation_id') ?? '')
  if (!simulationId) return go('erro:requisicao_invalida')
  const { error } = await supabase.rpc('create_proposal_from_simulation', { p_simulation_id: simulationId })
  if (error) {
    // The RPC locks the simulation and flips it to "selected" atomically: a double submit reaches one of these two refusals.
    if (error.code === '23505' || /simulation_not_available_for_proposal/.test(error.message ?? '')) return go('erro:proposta_duplicada')
    if (/simulation_not_found_or_forbidden|published_table_version_not_available|customer_not_available/.test(error.message ?? '')) return go('erro:simulacao_indisponivel')
    return go(classifyDbFeedback(error))
  }
  revalidatePath('/app/simulacoes'); revalidatePath('/app/propostas'); revalidatePath('/app')
  return go('ok:proposta_criada', '/app/propostas')
}
