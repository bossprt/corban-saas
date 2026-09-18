'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

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
  const { supabase, user, membership } = await requireAppContext()
  const customerId = String(formData.get('customer_id') ?? '')
  const tableVersionId = String(formData.get('product_table_version_id') ?? '')
  const requestedAmount = money(formData.get('requested_amount'))
  const term = integer(formData.get('term'))

  if (!customerId || !tableVersionId || requestedAmount === null || !term) {
    throw new Error('Dados obrigatórios da simulação são inválidos.')
  }

  const [{ data: customer }, { data: version }] = await Promise.all([
    supabase.from('clients').select('id,full_name').eq('id', customerId).is('deleted_at', null).maybeSingle(),
    supabase.from('product_table_versions')
      .select('id,product_table_id,status,term_min,term_max,rate,coefficient,metadata')
      .eq('id', tableVersionId).eq('status', 'published').maybeSingle(),
  ])

  if (!customer || !version) throw new Error('Cliente ou tabela publicada indisponível neste tenant.')
  if (version.term_min !== null && term < version.term_min) throw new Error('Prazo abaixo do permitido pela tabela.')
  if (version.term_max !== null && term > version.term_max) throw new Error('Prazo acima do permitido pela tabela.')

  const coefficient = version.coefficient === null ? null : Number(version.coefficient)
  const installmentAmount = coefficient && coefficient > 0
    ? Number((requestedAmount * coefficient).toFixed(2))
    : null

  const { error } = await supabase.from('simulations').insert({
    organization_id: membership.organization_id,
    customer_id: customer.id,
    product_table_version_id: version.id,
    status: 'calculated',
    requested_amount: requestedAmount,
    installment_amount: installmentAmount,
    term,
    rate: version.rate,
    coefficient: version.coefficient,
    input_snapshot: { requested_amount: requestedAmount, term },
    result_snapshot: {
      calculation: coefficient ? 'requested_amount_x_coefficient' : 'manual_pending',
      table_metadata: version.metadata,
    },
    created_by: user.id,
  })

  if (error) throw new Error('Não foi possível registrar a simulação.')
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
