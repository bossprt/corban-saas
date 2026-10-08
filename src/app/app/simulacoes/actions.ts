'use server'

import { crmBack } from '@/lib/safe-back'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifySimulationError } from '@/lib/simulation'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseMoneyInput } from '@/lib/money-input'
import { isUuid } from '@/lib/team'

const go = (code: FeedbackCode, path = '/app/simulacoes'): never => redirect(feedbackUrl(path, code))
// From the lead panel in Vendas the form carries "back": success and refusals return there.
const goFrom = (f: FormData) => (code: FeedbackCode, path?: string): never => go(code, crmBack(f.get('back')) ?? path)

// Amount typed as "10.000,00" becomes the exact decimal string "10000.00" (never a JavaScript number).
function money(value: FormDataEntryValue | null): string | null {
  const v = parseMoneyInput(value)
  return v && v !== 'invalid' && !/^0+\.00$/.test(v) && v.split('.')[0].length <= 9 ? v : null
}

function integer(value: FormDataEntryValue | null) {
  const parsed = Number.parseInt(String(value ?? ''), 10)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null
}

export async function createSimulation(formData: FormData) {
  // The screen sends one choice "<table version>|<contract type or empty>".
  const choice = formData.get('table_choice')
  if (choice !== null) {
    const [version, type = ''] = String(choice).split('|')
    formData.set('product_table_version_id', version)
    formData.set('contract_type_id', type)
  }
  if (String(formData.get('contract_type_id') ?? '') !== '') return createSimulationForCondition(formData)
  const { supabase } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const tableVersionId = String(formData.get('product_table_version_id') ?? '')
  const requestedAmount = money(formData.get('requested_amount'))
  const term = integer(formData.get('term'))
  if (!isUuid(customerId) || !isUuid(tableVersionId)) return go('erro:requisicao_invalida')
  if (requestedAmount === null) return go('erro:sim_invalid_amount')
  if (!term) return go('erro:sim_invalid_term')

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
  const amount = money(formData.get('requested_amount'))
  const term = integer(formData.get('term'))
  if (!isUuid(customerId) || !isUuid(versionId) || !isUuid(typeId)) return go('erro:requisicao_invalida')
  if (amount === null) return go('erro:sim_invalid_amount')
  if (!term) return go('erro:sim_invalid_term')
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
  const go = goFrom(formData)
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
  revalidatePath('/app/simulacoes'); revalidatePath('/app/propostas'); revalidatePath('/app'); revalidatePath('/app/crm')
  return go('ok:proposta_criada', '/app/propostas')
}

// The offer chosen on the simulator (08/10/2026): the database recalculates it from the factor in force and saves it as
// a simulation of the client; nothing but ids and the typed amounts comes from the browser.
export async function saveOffer(formData: FormData) {
  const go = goFrom(formData)
  const { supabase } = await requireAppContext()
  const ids = ['customer_id', 'table_version_id', 'condition_id', 'agreement_id', 'contract_type_id'].map(k => String(formData.get(k) ?? ''))
  const mode = String(formData.get('mode') ?? '')
  const value = money(formData.get('value'))
  const term = integer(formData.get('term'))
  const outstandingRaw = String(formData.get('outstanding') ?? '')
  const outstanding = outstandingRaw ? parseMoneyInput(outstandingRaw) : null
  if (!ids.every(isUuid) || !['amount', 'installment'].includes(mode)) return go('erro:requisicao_invalida')
  if (value === null || outstanding === 'invalid') return go('erro:sim_invalid_amount')
  if (!term) return go('erro:sim_invalid_term')
  const [customer, version, condition, agreement, type] = ids
  const { error } = await supabase.rpc('save_simulation_offer', {
    p_customer: customer, p_table_version: version, p_condition: condition, p_agreement: agreement, p_contract_type: type,
    p_term: term, p_mode: mode, p_value: value, p_outstanding: outstanding,
  })
  if (error) {
    const m = error.message ?? ''
    if (/offer_not_available|published_table_version_not_available/.test(m)) return go('erro:sim_oferta_indisponivel')
    if (/outstanding_above_amount/.test(m)) return go('erro:sim_saldo_maior')
    return go(classifyDbFeedback(error))
  }
  revalidatePath('/app/simulacoes'); revalidatePath('/app')
  return go('ok:simulacao_registrada')
}
