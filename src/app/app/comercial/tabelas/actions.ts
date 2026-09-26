'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, type FeedbackCode } from '@/lib/feedback'
import { parseValueInput } from '@/lib/commission/tableValues'
import { normalizePct } from '@/lib/commission/groupRule'
import { isUuid } from '@/lib/team'

const LIST = '/app/comercial/tabelas'
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
const tablePage = (id: string, version?: string) => `${LIST}/${id}${version ? `?v=${version}` : ''}`
const manager = async () => { const ctx = await requireAppContext(); return atLeast(ctx.membership.role, 'manager') ? ctx : null }
const go = (path: string, code: FeedbackCode): never => { revalidatePath(LIST); return redirect(feedbackUrl(path, code)) }

// 👁 Rename a table (only the name; bank, agreement and origin define the table and do not change).
export async function renameTable(f: FormData) {
  const id = text(f, 'table_id'), name = text(f, 'name')
  if (!isUuid(id)) return go(LIST, 'erro:requisicao_invalida')
  const ctx = await manager(); if (!ctx) return go(tablePage(id), 'erro:sem_permissao')
  if (name.length < 2 || name.length > 160) return go(tablePage(id), 'erro:tabela_nome')
  const { error } = await ctx.supabase.from('product_tables').update({ name, updated_at: new Date().toISOString() }).eq('id', id)
  return go(tablePage(id), error ? classifyDbFeedback(error) : 'ok:tabela_renomeada')
}

// $ Start a new "vigência" as a copy of the chosen one (or open the draft that already exists).
export async function cloneVersion(f: FormData) {
  const id = text(f, 'table_id'), version = text(f, 'version_id')
  if (!isUuid(id) || !isUuid(version)) return go(LIST, 'erro:requisicao_invalida')
  const ctx = await manager(); if (!ctx) return go(tablePage(id), 'erro:sem_permissao')
  const { data, error } = await ctx.supabase.rpc('clone_table_version', { p_version: version })
  if (error) return go(tablePage(id, version), classifyDbFeedback(error))
  return go(tablePage(id, data as string), 'ok:vigencia_rascunho')
}

export async function publishVersion(f: FormData) {
  const id = text(f, 'table_id'), version = text(f, 'version_id')
  if (!isUuid(id) || !isUuid(version)) return go(LIST, 'erro:requisicao_invalida')
  const ctx = await manager(); if (!ctx) return go(tablePage(id, version), 'erro:sem_permissao')
  const { error } = await ctx.supabase.rpc('publish_product_table_version', { p_version_id: version })
  if (error) return go(tablePage(id, version), /rate_or_coefficient_required/.test(error.message ?? '') ? 'erro:vigencia_sem_taxa' : classifyDbFeedback(error))
  return go(tablePage(id, version), 'ok:vigencia_publicada')
}

// $ Save what the company receives and what each group gets on one draft line (one database call, all or nothing).
export async function saveLineValues(f: FormData) {
  const id = text(f, 'table_id'), version = text(f, 'version_id'), condition = text(f, 'condition_id')
  if (!isUuid(id) || !isUuid(version) || !isUuid(condition)) return go(LIST, 'erro:requisicao_invalida')
  const back = `${LIST}/${id}/linha/${condition}`
  const ctx = await manager(); if (!ctx) return go(back, 'erro:sem_permissao')
  const base = text(f, 'calculation_base') || null
  const taxRaw = text(f, 'tax_pct').replace(/%$/, '').trim()
  const tax = taxRaw === '' ? '' : normalizePct(taxRaw)
  if (tax === null) return go(back, 'erro:linha_imposto_invalido')
  const components: { component_type_id: string; value_kind: string; received_value: string; calculation_base: string | null; source: string }[] = []
  const groupValues: { group_id: string; component_type_id: string; value_kind: string; value: string; source: string }[] = []
  for (const [key, raw] of f.entries()) {
    const m = /^(c|g)_([0-9a-f-]{36})(?:_([0-9a-f-]{36}))?$/.exec(key)
    if (!m) continue
    const parsed = parseValueInput(String(raw))
    if (parsed === null) return go(back, 'erro:linha_valor_invalido')
    if (parsed === 'empty' || Number(parsed.value) === 0) continue
    if (m[1] === 'c') components.push({ component_type_id: m[2], value_kind: parsed.kind, received_value: parsed.value, calculation_base: base, source: 'manual' })
    else if (m[3]) groupValues.push({ group_id: m[2], component_type_id: m[3], value_kind: parsed.kind, value: parsed.value, source: 'manual' })
  }
  // A % without its base would be refused by the calculation: ask for it here.
  if (!base && components.some(c => c.value_kind === 'percentage')) return go(back, 'erro:linha_sem_base')
  const { error } = await ctx.supabase.rpc('save_condition_values', { p_condition: condition, p_components: components, p_group_values: groupValues, p_tax_pct: tax })
  if (error) {
    const m = error.message ?? ''
    return go(back, /version_not_draft/.test(m) ? 'erro:vigencia_publicada_imutavel' : /invalid_group_value|invalid_components|invalid_tax_pct/.test(m) ? 'erro:linha_valor_invalido' : classifyDbFeedback(error))
  }
  return go(tablePage(id, version), 'ok:linha_salva')
}
