'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isValidCpf } from '@/lib/cpf'
import { CAMPAIGN_LIMITS, isDistribution, localDateTimeToIso, MANUAL_STAGES, type CampaignRow, type LeadStage } from '@/lib/crm'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const DATE = /^\d{4}-\d{2}-\d{2}$/
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const leadPath = (id: string) => `/app/crm/leads/${id}`
const go = (path: string, code: FeedbackCode): never => redirect(feedbackUrl(path, code))
// A safe "back to" path: only the CRM screens (never an external URL).
const back = (f: FormData, fallback: string) => {
  const v = text(f, 'back')
  return /^\/app\/crm(\/[\w-]+)*(\?[\w=&%-]*)?$/.test(v) ? v : fallback
}

function crmError(error: { message?: string; code?: string }): FeedbackCode {
  const m = error.message ?? ''
  if (/lead_already_in_campaign/.test(m)) return 'erro:lead_ja_na_campanha'
  if (/lead_has_open_proposal/.test(m)) return 'erro:lead_com_proposta'
  if (/lead_already_won|lead_closed/.test(m)) return 'erro:lead_fechado'
  if (/lead_reactivation_requires_supervisor/.test(m)) return 'erro:lead_reativar_supervisor'
  if (/lost_reason_required/.test(m)) return 'erro:motivo_obrigatorio'
  if (/campaign_name_taken/.test(m)) return 'erro:campanha_nome_repetido'
  if (/round_robin_needs_members/.test(m)) return 'erro:campanha_rodizio_sem_vendedor'
  if (/campaign_not_active/.test(m)) return 'erro:campanha_encerrada'
  if (/invalid_lead_owner|invalid_campaign_member/.test(m)) return 'erro:vendedor_invalido'
  if (/lead_already_taken/.test(m)) return 'erro:lead_ja_assumido'
  if (/campaign_name_mismatch/.test(m)) return 'erro:campanha_nome_confirmacao'
  if (/campaign_has_sales/.test(m)) return 'erro:campanha_com_vendas'
  return classifyDbFeedback(error)
}

function refresh(...paths: string[]) {
  for (const p of ['/app/crm', '/app/hoje', '/app', ...paths]) revalidatePath(p)
}

export async function createSalesLead(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const name = text(formData, 'full_name')
  const cpf = text(formData, 'cpf').replace(/\D/g, '')
  const phone = text(formData, 'phone')
  const campaign = text(formData, 'campaign_id')
  if (name.length < 2 || name.length > 200) return go('/app/crm', 'erro:nome_invalido')
  if (cpf && !isValidCpf(cpf)) return go('/app/crm', 'erro:cpf_invalido')
  if (!cpf && phone.replace(/\D/g, '').length < 10) return go('/app/crm', 'erro:lead_sem_contato')
  if (campaign && !UUID.test(campaign)) return go('/app/crm', 'erro:requisicao_invalida')
  const { data, error } = await supabase.rpc('create_sales_lead', {
    p_organization_id: organization.id, p_full_name: name, p_phone: phone || null, p_cpf: cpf || null,
    p_email: text(formData, 'email') || null, p_campaign_id: campaign || null,
  })
  if (error) return go('/app/crm', crmError(error))
  refresh()
  return go(leadPath(String(data)), 'ok:lead_registrado')
}

export async function setLeadStage(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = text(formData, 'lead_id')
  const stage = text(formData, 'status') as LeadStage
  const reason = text(formData, 'lost_reason')
  const to = back(formData, UUID.test(id) ? leadPath(id) : '/app/crm')
  if (!UUID.test(id) || !MANUAL_STAGES.includes(stage)) return go(to, 'erro:requisicao_invalida')
  if (stage === 'lost' && !reason) return go(to, 'erro:motivo_obrigatorio')
  if (reason.length > 300) return go(to, 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('set_lead_status', { p_lead_id: id, p_status: stage, p_lost_reason: reason || null })
  if (error) return go(to, crmError(error))
  refresh(leadPath(id))
  return go(to, 'ok:lead_atualizado')
}

// Board drag and drop: same rule as setLeadStage, answered in place (no redirect) so the board just refreshes.
export async function moveLeadOnBoard(leadId: string, stage: string): Promise<{ ok: true } | { ok: false; message: string }> {
  const { supabase } = await requireAppContext()
  if (!UUID.test(leadId) || !MANUAL_STAGES.includes(stage as LeadStage) || stage === 'lost') return { ok: false, message: 'Movimento não permitido.' }
  const { error } = await supabase.rpc('set_lead_status', { p_lead_id: leadId, p_status: stage, p_lost_reason: null })
  if (error) {
    const code = crmError(error)
    return { ok: false, message: code === 'erro:lead_com_proposta' ? 'Este lead tem proposta em andamento: a etapa segue a proposta.' : 'Não foi possível mover o lead.' }
  }
  refresh(leadPath(leadId))
  return { ok: true }
}

export async function setNextContact(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = text(formData, 'lead_id')
  if (!UUID.test(id)) return go('/app/crm', 'erro:requisicao_invalida')
  const raw = text(formData, 'next_contact_at')
  const at = raw ? localDateTimeToIso(raw) : null
  if (raw && !at) return go(leadPath(id), 'erro:data_invalida')
  const { error } = await supabase.rpc('set_lead_next_contact', { p_lead_id: id, p_at: at })
  if (error) return go(leadPath(id), crmError(error))
  const note = text(formData, 'note')
  if (note) {
    const { error: e } = await supabase.rpc('add_lead_note', { p_lead_id: id, p_text: note.slice(0, 1000) })
    if (e) return go(leadPath(id), crmError(e))
  }
  refresh(leadPath(id))
  return go(leadPath(id), at ? 'ok:retorno_marcado' : 'ok:lead_atualizado')
}

export async function addLeadNote(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = text(formData, 'lead_id')
  const note = text(formData, 'note')
  if (!UUID.test(id)) return go('/app/crm', 'erro:requisicao_invalida')
  if (!note || note.length > 1000) return go(leadPath(id), 'erro:anotacao_invalida')
  const { error } = await supabase.rpc('add_lead_note', { p_lead_id: id, p_text: note })
  if (error) return go(leadPath(id), crmError(error))
  refresh(leadPath(id))
  return go(leadPath(id), 'ok:anotacao_salva')
}

// "Simular": the lead becomes (or is recognized as) a client by CPF and the simulation opens with that client chosen.
export async function startLeadSale(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = text(formData, 'lead_id')
  const cpf = text(formData, 'cpf').replace(/\D/g, '')
  if (!UUID.test(id)) return go('/app/crm', 'erro:requisicao_invalida')
  if (cpf && !isValidCpf(cpf)) return go(leadPath(id), 'erro:cpf_invalido')
  const { data, error } = await supabase.rpc('start_lead_sale', { p_lead_id: id, p_cpf: cpf || null })
  if (error) return go(leadPath(id), crmError(error))
  refresh(leadPath(id), '/app/clientes')
  redirect(`/app/simulacoes?cliente=${String(data)}`)
}

export async function takeNextLead(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const campaign = text(formData, 'campaign_id')
  if (campaign && !UUID.test(campaign)) return go('/app/crm', 'erro:requisicao_invalida')
  const { data, error } = await supabase.rpc('take_next_lead', { p_org: organization.id, p_campaign: campaign || null })
  if (error) return go('/app/crm', crmError(error))
  if (!data) return go('/app/crm', 'erro:fila_vazia')
  refresh()
  return go(leadPath(String(data)), 'ok:lead_assumido')
}

export async function claimLead(formData: FormData) {
  const { supabase } = await requireAppContext()
  const id = text(formData, 'lead_id')
  if (!UUID.test(id)) return go('/app/crm', 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('claim_lead', { p_lead: id })
  if (error) return go(leadPath(id), crmError(error))
  refresh(leadPath(id))
  return go(leadPath(id), 'ok:lead_assumido')
}

// Supervisor: one lead to a seller (lead page), or the N oldest waiting leads of a campaign (campaign page).
export async function assignLeads(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const owner = text(formData, 'owner_user_id')
  const leadId = text(formData, 'lead_id')
  const campaign = text(formData, 'campaign_id')
  const count = Number(text(formData, 'count'))
  const to = back(formData, '/app/crm')
  if (!UUID.test(owner)) return go(to, 'erro:vendedor_invalido')
  let args: { p_lead_ids: string[] | null; p_campaign: string | null; p_count: number | null }
  if (UUID.test(leadId)) args = { p_lead_ids: [leadId], p_campaign: null, p_count: null }
  else if (UUID.test(campaign) && Number.isInteger(count) && count >= 1 && count <= 1000) args = { p_lead_ids: null, p_campaign: campaign, p_count: count }
  else return go(to, 'erro:requisicao_invalida')
  const { data, error } = await supabase.rpc('assign_leads', { p_org: organization.id, p_owner: owner, ...args })
  if (error) return go(to, crmError(error))
  refresh()
  return go(to, Number(data) > 0 ? 'ok:leads_distribuidos' : 'erro:nada_para_distribuir')
}

export async function saveCampaign(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const id = text(formData, 'campaign_id')
  const name = text(formData, 'name')
  const distribution = text(formData, 'distribution')
  const starts = text(formData, 'starts_on')
  const ends = text(formData, 'ends_on')
  const status = text(formData, 'status') || 'active'
  const members = formData.getAll('members').map(String).filter(m => UUID.test(m))
  const to = id ? `/app/crm/campanhas/${id}` : '/app/crm/campanhas'
  if ((id && !UUID.test(id)) || name.length < 2 || name.length > 120 || !isDistribution(distribution) || !['active', 'closed'].includes(status)
      || (starts && !DATE.test(starts)) || (ends && !DATE.test(ends))) return go(to, 'erro:requisicao_invalida')
  if (starts && ends && ends < starts) return go(to, 'erro:periodo_invalido')
  const { data, error } = await supabase.rpc('save_sales_campaign', {
    p_org: organization.id, p_id: id || null, p_name: name, p_description: text(formData, 'description').slice(0, 500) || null,
    p_distribution: distribution, p_starts_on: starts || null, p_ends_on: ends || null, p_status: status, p_members: members,
  })
  if (error) return go(to, crmError(error))
  refresh('/app/crm/campanhas')
  return go(`/app/crm/campanhas/${String(data)}`, id ? 'ok:campanha_salva' : 'ok:campanha_criada')
}

export type CampaignImportResult = { ok: true; created: number; linked: number; duplicates: number; invalid: number } | { ok: false; message: string }

// One chunk of the spreadsheet (read in the browser; Vercel caps a request at 4.5 MB). The database validates every row.
export async function importCampaignChunk(input: { campaignId: string; fileName: string; sha: string; rows: CampaignRow[] }): Promise<CampaignImportResult> {
  const { supabase } = await requireAppContext()
  const { campaignId, fileName, sha, rows } = input ?? {}
  if (!UUID.test(String(campaignId)) || !/^[0-9a-f]{64}$/.test(String(sha)) || typeof fileName !== 'string' || !fileName.trim()
      || !Array.isArray(rows) || rows.length === 0 || rows.length > CAMPAIGN_LIMITS.chunk) return { ok: false, message: 'Arquivo ou linhas inválidos.' }
  const clean = rows.map(r => {
    const o: Record<string, unknown> = {}
    for (const k of ['name', 'cpf', 'phone', 'phone2', 'email'] as const) if (typeof r?.[k] === 'string') o[k] = r[k]!.slice(0, 200)
    if (r?.info && typeof r.info === 'object') {
      o.info = Object.fromEntries(Object.entries(r.info).slice(0, CAMPAIGN_LIMITS.infoColumns)
        .filter(([, v]) => typeof v === 'string').map(([k, v]) => [String(k).slice(0, 60), String(v).slice(0, CAMPAIGN_LIMITS.infoValue)]))
    }
    return o
  })
  const { data, error } = await supabase.rpc('import_campaign_leads', { p_campaign: campaignId, p_file_name: fileName.trim().slice(0, 255), p_file_sha256: sha, p_rows: clean })
  if (error) {
    const code = crmError(error)
    return { ok: false, message: code === 'erro:campanha_encerrada' ? 'A campanha está encerrada.' : code === 'erro:sem_permissao' ? 'Sem permissão para importar.' : 'Não foi possível importar esta parte do arquivo.' }
  }
  const r = data as { created: number; linked_clients: number; duplicates: number; invalid: number }
  revalidatePath('/app/crm'); revalidatePath(`/app/crm/campanhas/${campaignId}`)
  return { ok: true, created: r.created, linked: r.linked_clients, duplicates: r.duplicates, invalid: r.invalid }
}

// Board search by CPF: sent by POST (never in the URL); returns the most recent lead the caller can see with that CPF.
export async function findLeadByCpf(raw: string): Promise<string | null> {
  const { supabase } = await requireAppContext()
  const cpf = String(raw ?? '').replace(/\D/g, '')
  if (cpf.length !== 11) return null
  const { data } = await supabase.from('leads').select('id').eq('cpf', cpf).order('created_at', { ascending: false }).limit(1).maybeSingle()
  return data?.id ?? null
}

// Test campaign or wrong import (08/10/2026): the campaign, its leads and their history go away; never when a lead became
// a proposal or a sale; clients stay. The name is typed to confirm.
export async function deleteCampaign(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const id = text(formData, 'campaign_id')
  if (!UUID.test(id)) return go('/app/crm/campanhas', 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('delete_sales_campaign', { p_org: organization.id, p_campaign: id, p_confirm_name: text(formData, 'confirm_name') })
  if (error) return go(`/app/crm/campanhas/${id}`, crmError(error))
  refresh('/app/crm', '/app/crm/campanhas')
  return go('/app/crm/campanhas', 'ok:campanha_excluida')
}

// Campaign over (08/10/2026): closed, and its open leads go to Lost with the reason "Campanha encerrada".
export async function closeCampaign(formData: FormData) {
  const { supabase, organization } = await requireAppContext()
  const id = text(formData, 'campaign_id')
  if (!UUID.test(id)) return go('/app/crm/campanhas', 'erro:requisicao_invalida')
  const { error } = await supabase.rpc('close_sales_campaign', { p_org: organization.id, p_campaign: id })
  if (error) return go(`/app/crm/campanhas/${id}`, crmError(error))
  refresh('/app/crm', '/app/crm/campanhas', `/app/crm/campanhas/${id}`)
  return go(`/app/crm/campanhas/${id}`, 'ok:campanha_encerrada')
}
