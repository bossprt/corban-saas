'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CHANNELS = new Set(['whatsapp', 'meta_ads', 'api', 'import', 'manual', 'referral', 'other'])
const STATUSES = new Set(['new', 'contacted', 'qualified', 'lost'])

// Every tenant decision is made by the database: intake sends the ACTIVE organization (validated against membership there);
// status/conversion send only the lead id and the database derives the organization from the lead.
export async function createLead(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const name = String(formData.get('full_name') ?? '').trim()
  const channel = String(formData.get('channel') ?? 'manual')
  if (name.length < 2 || name.length > 200) throw new Error('Nome inválido')
  if (!CHANNELS.has(channel)) throw new Error('Canal inválido')
  const { error } = await supabase.rpc('create_lead', {
    p_organization_id: organization.id, p_channel: channel, p_full_name: name,
    p_phone: String(formData.get('phone') ?? '').trim() || null, p_email: String(formData.get('email') ?? '').trim() || null,
    p_campaign: String(formData.get('campaign') ?? '').trim() || null, p_external_ref: null
  })
  if (error) throw new Error('Não foi possível registrar o lead')
  revalidatePath('/app/leads')
}

export async function setLeadStatus(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = String(formData.get('lead_id') ?? '')
  const status = String(formData.get('status') ?? '')
  const reason = String(formData.get('lost_reason') ?? '').trim() || null
  if (!UUID.test(id) || !STATUSES.has(status)) throw new Error('Requisição inválida')
  if (status === 'lost' && !reason) throw new Error('Informe o motivo da perda')
  const { error } = await supabase.rpc('set_lead_status', { p_lead_id: id, p_status: status, p_lost_reason: reason })
  if (error) throw new Error('Não foi possível alterar o status do lead')
  revalidatePath('/app/leads')
}

export async function convertLead(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = String(formData.get('lead_id') ?? '')
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  if (!UUID.test(id)) throw new Error('Requisição inválida')
  if (!/^\d{11}$/.test(cpf)) throw new Error('CPF inválido')
  const { error } = await supabase.rpc('convert_lead_to_customer', { p_lead_id: id, p_cpf: cpf })
  if (error) throw new Error(error.code === '23505' ? 'CPF já cadastrado neste tenant' : 'Não foi possível converter o lead')
  revalidatePath('/app/leads'); revalidatePath('/app/clientes')
}
