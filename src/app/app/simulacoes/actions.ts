'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { SIMULATION_ERRORS, classifySimulationError } from '@/lib/simulation'

function money(value: FormDataEntryValue | null) {
  const normalized = String(value ?? '').trim().replace(',', '.')
  const parsed = Number(normalized)
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null
}

function integer(value: FormDataEntryValue | null) {
  const parsed = Number.parseInt(String(value ?? ''), 10)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : null
}

async function legacyInsert(customerId: string, tableVersionId: string, requestedAmount: number, term: number) {
  const { supabase, user, membership } = await requireAppContext()
  const [{ data: customer }, { data: version }] = await Promise.all([
    supabase.from('clients').select('id').eq('id', customerId).is('deleted_at', null).maybeSingle(),
    supabase.from('product_table_versions').select('id,status,term_min,term_max,rate,coefficient').eq('id', tableVersionId).eq('status', 'published').maybeSingle(),
  ])
  if (!customer || !version) throw new Error(SIMULATION_ERRORS.published_table_version_not_available)
  if (version.term_min !== null && term < version.term_min) throw new Error(SIMULATION_ERRORS.term_below_table_minimum)
  if (version.term_max !== null && term > version.term_max) throw new Error(SIMULATION_ERRORS.term_above_table_maximum)
  const coefficient = version.coefficient === null ? null : Number(version.coefficient)
  const { error } = await supabase.from('simulations').insert({
    organization_id: membership.organization_id, customer_id: customer.id, product_table_version_id: version.id, status: 'calculated',
    requested_amount: requestedAmount, installment_amount: coefficient && coefficient > 0 ? Number((requestedAmount * coefficient).toFixed(2)) : null,
    term, rate: version.rate, coefficient: version.coefficient,
    input_snapshot: { requested_amount: requestedAmount, term }, result_snapshot: { calculation: coefficient ? 'requested_amount_x_coefficient' : 'manual_pending' },
    created_by: user.id,
  })
  if (error) throw new Error(SIMULATION_ERRORS.unexpected)
}

export async function createSimulation(formData: FormData) {
  const { supabase } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const tableVersionId = String(formData.get('product_table_version_id') ?? '')
  const requestedAmount = money(formData.get('requested_amount'))
  const term = integer(formData.get('term'))

  if (!customerId || !tableVersionId || requestedAmount === null || requestedAmount <= 0 || !term) {
    throw new Error('Dados obrigatórios da simulação são inválidos.')
  }

  // The database derives the tenant from the customer, checks that the table version is published for THAT tenant, applies the table rate and
  // coefficient, computes the installment and records the actor. Nothing but the four ids/numbers above comes from the browser.
  const { error } = await supabase.rpc('create_simulation', {
    p_customer_id: customerId,
    p_table_version_id: tableVersionId,
    p_requested_amount: requestedAmount,
    p_term: term,
  })
  const code = error ? classifySimulationError(error) : null
  // TEMPORARY compatibility: before 20260926_simulation_governance_v1 is applied the RPC does not exist and the old server-computed insert keeps
  // simulations working. Once the migration is LIVE the database refuses that insert, so this branch can never bypass the governed path; remove it then.
  if (code === 'rpc_unavailable') await legacyInsert(customerId, tableVersionId, requestedAmount, term)
  else if (code) throw new Error(SIMULATION_ERRORS[code])
  revalidatePath('/app/simulacoes')
  revalidatePath('/app')
}

export async function createProposalFromSimulation(formData: FormData) {
  const { supabase } = await requireAppContext()
  const simulationId = String(formData.get('simulation_id') ?? '')
  if (!simulationId) throw new Error('Simulação inválida.')

  const { error } = await supabase.rpc('create_proposal_from_simulation', {
    p_simulation_id: simulationId,
  })

  if (error) {
    if (error.code === '23505') throw new Error('Esta simulação já possui proposta.')
    throw new Error('Não foi possível criar a proposta de forma atômica.')
  }

  revalidatePath('/app/simulacoes')
  revalidatePath('/app/propostas')
  revalidatePath('/app')
}
