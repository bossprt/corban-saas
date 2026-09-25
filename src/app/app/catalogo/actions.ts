'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { isCode, isLabel, missingStages, parseVersionForm } from '@/lib/catalog'
import { isUuid } from '@/lib/team'

const go = (code: FeedbackCode): never => { revalidatePath('/app/catalogo'); revalidatePath('/app/configuracao'); return redirect(feedbackUrl('/app/catalogo', code)) }
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
// Every write below is authorized by the database (RLS + guard triggers + governed RPCs); the role checks here only fail early with a clear message.
const catalogError = (e: { message?: string; code?: string }): FeedbackCode => {
  const m = String(e.message ?? '')
  if (e.code === '23505') return 'erro:duplicado'
  if (e.code === '23503' || e.code === '23514') return 'erro:catalogo_invalido' // FK/check: e.g. agreement of another bank, term range
  for (const c of ['rate_or_coefficient_required', 'version_not_draft', 'template_has_no_items', 'template_not_draft'] as const) if (m.includes(c)) return `erro:cat_${c}` as FeedbackCode
  return classifyDbFeedback(e)
}

export async function createRoute(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const ids = ['bank_id', 'provider_id', 'agreement_id', 'product_id', 'modality_id'].map(k => text(f, k))
  if (!ids.every(isUuid)) return go('erro:catalogo_invalido')
  const [bank_id, provider_id, agreement_id, product_id, modality_id] = ids
  const { error } = await supabase.from('organization_product_routes').insert({ organization_id: membership.organization_id, bank_id, provider_id, agreement_id, product_id, modality_id, status: 'active' })
  return error ? go(catalogError(error)) : go('ok:rota_criada')
}

export async function createTable(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const route_id = text(f, 'route_id'), code = text(f, 'code'), name = text(f, 'name')
  if (!isUuid(route_id) || !isCode(code) || !isLabel(name)) return go('erro:catalogo_invalido')
  const { error } = await supabase.from('product_tables').insert({ organization_id: membership.organization_id, route_id, code, name, status: 'active' })
  return error ? go(catalogError(error)) : go('ok:tabela_criada')
}

export async function createVersion(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const table_id = text(f, 'table_id')
  const v = parseVersionForm(f)
  if (!isUuid(table_id) || !v) return go('erro:catalogo_invalido')
  const { data: last } = await supabase.from('product_table_versions').select('version').eq('product_table_id', table_id).order('version', { ascending: false }).limit(1).maybeSingle()
  const { error } = await supabase.from('product_table_versions').insert({
    organization_id: membership.organization_id, product_table_id: table_id, version: (last?.version ?? 0) + 1, status: 'draft',
    rate: v.rate, coefficient: v.coefficient, term_min: v.termMin, term_max: v.termMax,
  })
  return error ? go(catalogError(error)) : go('ok:versao_criada')
}

export async function publishVersion(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const id = text(f, 'version_id')
  if (!isUuid(id)) return go('erro:catalogo_invalido')
  const { error } = await supabase.rpc('publish_product_table_version', { p_version_id: id })
  return error ? go(catalogError(error)) : go('ok:versao_publicada')
}

export async function createChecklist(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return go('erro:sem_permissao')
  const route_id = text(f, 'route_id'), name = text(f, 'name')
  if (!isUuid(route_id) || !isLabel(name)) return go('erro:catalogo_invalido')
  const { data: last } = await supabase.from('document_checklist_templates').select('version').eq('route_id', route_id).order('version', { ascending: false }).limit(1).maybeSingle()
  const { error } = await supabase.from('document_checklist_templates').insert({ organization_id: membership.organization_id, route_id, version: (last?.version ?? 0) + 1, status: 'draft', name })
  return error ? go(catalogError(error)) : go('ok:checklist_criado')
}

export async function addChecklistItem(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return go('erro:sem_permissao')
  const template_id = text(f, 'template_id'), document_type_id = text(f, 'document_type_id'), label = text(f, 'label')
  if (!isUuid(template_id) || !isUuid(document_type_id) || !isLabel(label)) return go('erro:catalogo_invalido')
  const { count } = await supabase.from('document_checklist_items').select('*', { count: 'exact', head: true }).eq('template_id', template_id)
  const { error } = await supabase.from('document_checklist_items').insert({ organization_id: membership.organization_id, template_id, document_type_id, label, is_required: f.get('is_required') === 'on', sort_order: count ?? 0 })
  return error ? go(catalogError(error)) : go('ok:item_adicionado')
}

export async function publishChecklist(f: FormData) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return go('erro:sem_permissao')
  const id = text(f, 'template_id')
  if (!isUuid(id)) return go('erro:catalogo_invalido')
  const { error } = await supabase.rpc('publish_document_checklist_template', { p_template_id: id })
  return error ? go(catalogError(error)) : go('ok:checklist_publicado')
}

// Creates ONLY the missing esteira stages (idempotent). No SLA is invented: minutes stay empty until the organization decides.
export async function createDefaultStages() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return go('erro:sem_permissao')
  const { data } = await supabase.from('operational_stages').select('canonical_state')
  const todo = missingStages((data ?? []).map(s => s.canonical_state))
  if (todo.length === 0) return go('ok:etapas_criadas')
  const { error } = await supabase.from('operational_stages').insert(todo.map(s => ({ organization_id: membership.organization_id, code: s.code, name: s.name, canonical_state: s.state, sort_order: s.sort, sla_minutes: null, is_active: true })))
  return error ? go(catalogError(error)) : go('ok:etapas_criadas')
}
