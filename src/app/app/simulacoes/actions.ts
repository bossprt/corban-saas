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
  const { supabase, user, membership } = await requireAppContext()
  const simulationId = String(formData.get('simulation_id') ?? '')
  if (!simulationId) throw new Error('Simulação inválida.')

  const { data: simulation } = await supabase.from('simulations')
    .select('id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,rate,coefficient,expected_commission_amount')
    .eq('id', simulationId).maybeSingle()

  if (!simulation || !['calculated', 'selected'].includes(simulation.status)) {
    throw new Error('Simulação não está disponível para proposta.')
  }

  const [{ data: customer }, { data: version }] = await Promise.all([
    supabase.from('clients')
      .select('id,full_name,cpf,phone,email,original_source')
      .eq('id', simulation.customer_id).is('deleted_at', null).maybeSingle(),
    supabase.from('product_table_versions')
      .select('id,status,version,product_table_id,rate,coefficient,metadata')
      .eq('id', simulation.product_table_version_id).eq('status', 'published').maybeSingle(),
  ])

  if (!customer || !version) throw new Error('Snapshot comercial não pode ser formado com segurança.')

  const { data: table } = await supabase.from('product_tables')
    .select('id,code,name,route_id').eq('id', version.product_table_id).maybeSingle()
  if (!table) throw new Error('Tabela comercial não encontrada.')

  const { data: proposal, error } = await supabase.from('proposals_v2').insert({
    organization_id: membership.organization_id,
    customer_id: customer.id,
    simulation_id: simulation.id,
    product_table_version_id: version.id,
    status: 'draft',
    requested_amount: simulation.requested_amount,
    released_amount: simulation.released_amount,
    installment_amount: simulation.installment_amount,
    term: simulation.term,
    rate: simulation.rate,
    coefficient: simulation.coefficient,
    expected_commission_amount: simulation.expected_commission_amount,
    customer_snapshot: {
      full_name: customer.full_name,
      cpf: customer.cpf,
      phone: customer.phone,
      email: customer.email,
    },
    commercial_snapshot: {
      product_table: { id: table.id, code: table.code, name: table.name },
      table_version: { id: version.id, version: version.version, rate: version.rate, coefficient: version.coefficient },
    },
    attribution_snapshot: { original_source: customer.original_source },
    created_by: user.id,
  }).select('id').single()

  if (error || !proposal) {
    if (error?.code === '23505') throw new Error('Esta simulação já possui proposta.')
    throw new Error('Não foi possível criar a proposta.')
  }

  await supabase.from('simulations').update({ status: 'selected' }).eq('id', simulation.id).eq('status', 'calculated')
  revalidatePath('/app/simulacoes')
  revalidatePath('/app/propostas')
  revalidatePath('/app')
}
