'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CHANNELS = new Set(['whatsapp', 'meta_ads', 'api', 'import', 'manual', 'referral', 'other'])
const STATUSES = new Set(['new', 'contacted', 'qualified', 'lost'])
const go = (code: FeedbackCode): never => redirect(feedbackUrl('/app/leads', code))

// Every tenant decision is made by the database: intake sends the ACTIVE organization (validated against membership there);
// status/conversion send only the lead id and the database derives the organization from the lead.
export async function createLead(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const name = String(formData.get('full_name') ?? '').trim()
  const channel = String(formData.get('channel') ?? 'manual')
  if (name.length < 2 || name.length > 200) return go('erro:nome_invalido')
  if (!CHANNELS.has(channel)) return go('erro:canal_invalido')
  const { error } = await supabase.rpc('create_lead', {
    p_organization_id: organization.id, p_channel: channel, p_full_name: name,
    p_phone: String(formData.get('phone') ?? '').trim() || null, p_email: String(formData.get('email') ?? '').trim() || null,
    p_campaign: String(formData.get('campaign') ?? '').trim() || null, p_external_ref: null
  })
  if (error) return go(classifyDbFeedback(error))
  revalidatePath('/app/leads'); revalidatePath('/app')
  return go('ok:lead_registrado')
}

export async function setLeadStatus(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = String(formData.get('lead_id') ?? '')
  const status = String(formData.get('status') ?? '')
  const reason = String(formData.get('lost_reason') ?? '').trim() || null
  if (!UUID.test(id) || !STATUSES.has(status)) return go('erro:requisicao_invalida')
  if (status === 'lost' && !reason) return go('erro:motivo_obrigatorio')
  const { error } = await supabase.rpc('set_lead_status', { p_lead_id: id, p_status: status, p_lost_reason: reason })
  if (error) return go(classifyDbFeedback(error))
  revalidatePath('/app/leads'); revalidatePath('/app')
  return go('ok:lead_atualizado')
}

// Idempotent in the database (a second click on an already converted lead returns the same customer), so a double submit cannot duplicate.
export async function convertLead(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = String(formData.get('lead_id') ?? '')
  const cpf = String(formData.get('cpf') ?? '').replace(/\D/g, '')
  if (!UUID.test(id)) return go('erro:requisicao_invalida')
  if (!isValidCpf(cpf)) return go('erro:cpf_invalido')
  const { error } = await supabase.rpc('convert_lead_to_customer', { p_lead_id: id, p_cpf: cpf })
  if (error) return go(classifyDbFeedback(error))
  revalidatePath('/app/leads'); revalidatePath('/app/clientes'); revalidatePath('/app')
  return go('ok:lead_convertido')
}
