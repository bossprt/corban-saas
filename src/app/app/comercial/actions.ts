'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, isFeedbackCode, type FeedbackCode } from '@/lib/feedback'
import { isLabel } from '@/lib/catalog'
import { isUuid } from '@/lib/team'

const PATH = '/app/comercial'
const RETURN_PATHS = new Set([PATH, `${PATH}/instituicoes`, `${PATH}/origens`, `${PATH}/convenios`, `${PATH}/grupos`])
const returnPath = (f: FormData) => { const p = String(f.get('return_to') ?? '').trim(); return RETURN_PATHS.has(p) ? p : PATH }
const go = (code: FeedbackCode, path = PATH): never => { revalidatePath(PATH); revalidatePath(path); revalidatePath('/app/configuracao'); return redirect(feedbackUrl(path, code)) }
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
// The database authorizes every write (RLS + guard triggers + governed RPC); the role check here only fails early with a clear message.
const COM_CODES = ['national_template_not_available'] as const
const comError = (e: { message?: string; code?: string }): FeedbackCode => {
  const m = String(e.message ?? '')
  if (e.code === '23505') return 'erro:duplicado'
  if (e.code === '23503' || e.code === '23514') return 'erro:catalogo_invalido'
  for (const c of COM_CODES) if (m.includes(c)) { const k = `erro:com_${c}`; if (isFeedbackCode(k)) return k }
  if (m.includes('rate_or_coefficient_required')) return 'erro:cat_rate_or_coefficient_required'
  return classifyDbFeedback(e)
}
const manager = async () => {
  const ctx = await requireAppContext()
  return atLeast(ctx.membership.role, 'manager') ? ctx : null
}

export async function createBank(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const name = text(f, 'name')
  if (!isLabel(name)) return go('erro:nome_invalido', returnPath(f))
  const { error } = await ctx.supabase.from('organization_banks').insert({ organization_id: ctx.membership.organization_id, name })
  return error ? go(comError(error), returnPath(f)) : go('ok:banco_cadastrado', returnPath(f))
}

export async function createProvider(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const name = text(f, 'name'), type = text(f, 'provider_type')
  if (!isLabel(name) || !['bank_direct', 'master', 'promotora', 'correspondent', 'partner', 'other'].includes(type)) return go('erro:nome_invalido', returnPath(f))
  const { error } = await ctx.supabase.from('organization_providers').insert({ organization_id: ctx.membership.organization_id, name, provider_type: type })
  return error ? go(comError(error), returnPath(f)) : go('ok:provedor_cadastrado', returnPath(f))
}

// Enabling a national template gives the OFFICIAL name (the database forces it); the tenant chooses which ones it works with.
export async function enableAgreementTemplate(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const template_id = text(f, 'template_id')
  if (!isUuid(template_id)) return go('erro:catalogo_invalido', returnPath(f))
  const { error } = await ctx.supabase.from('organization_agreements').insert({ organization_id: ctx.membership.organization_id, template_id, name: 'nacional' })
  return error ? go(comError(error), returnPath(f)) : go('ok:convenio_habilitado', returnPath(f))
}

export async function createAgreement(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const name = text(f, 'name')
  if (!isLabel(name)) return go('erro:nome_invalido')
  const { error } = await ctx.supabase.from('organization_agreements').insert({ organization_id: ctx.membership.organization_id, name })
  return error ? go(comError(error), returnPath(f)) : go('ok:convenio_cadastrado', returnPath(f))
}

// Deactivate / reactivate. Nothing is ever deleted: history keeps pointing at the row.
export async function setActive(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const table = text(f, 'kind'), id = text(f, 'id'), active = text(f, 'active') === 'true'
  const allowed = { bank: 'organization_banks', provider: 'organization_providers', agreement: 'organization_agreements', group: 'commission_groups' } as const
  if (!isUuid(id) || !Object.prototype.hasOwnProperty.call(allowed, table)) return go('erro:catalogo_invalido', returnPath(f))
  const { error } = await ctx.supabase.from(allowed[table as keyof typeof allowed]).update({ is_active: active }).eq('id', id)
  return error ? go(comError(error), returnPath(f)) : go('ok:situacao_atualizada', returnPath(f))
}


export async function renameCatalogItem(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const table = text(f, 'kind'), id = text(f, 'id'), name = text(f, 'name')
  const allowed = { bank: 'organization_banks', provider: 'organization_providers', agreement: 'organization_agreements', group: 'commission_groups' } as const
  if (!isUuid(id) || !Object.prototype.hasOwnProperty.call(allowed, table) || !isLabel(name, table === 'group' ? 80 : 120)) return go('erro:nome_invalido', returnPath(f))
  const { error } = await ctx.supabase.from(allowed[table as keyof typeof allowed]).update({ name }).eq('id', id)
  return error ? go(comError(error), returnPath(f)) : go('ok:situacao_atualizada', returnPath(f))
}


export async function updateProvider(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const id = text(f, 'id'), name = text(f, 'name'), type = text(f, 'provider_type')
  if (!isUuid(id) || !isLabel(name) || !['bank_direct', 'master', 'promotora', 'correspondent', 'partner', 'other'].includes(type)) return go('erro:catalogo_invalido', returnPath(f))
  const { error } = await ctx.supabase.from('organization_providers').update({ name, provider_type: type }).eq('id', id)
  return error ? go(comError(error), returnPath(f)) : go('ok:situacao_atualizada', returnPath(f))
}

// A commercial table = bank + agreement (+ optional provider). The route and the technical code are generated here; the person only names the table.
const NEW_TABLE = `${PATH}/tabelas/nova`
export async function createCommercialTable(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao', NEW_TABLE)
  const bank = text(f, 'bank_id'), agreement = text(f, 'agreement_id'), name = text(f, 'name'), origin = text(f, 'production_origin')
  // Origem da Produção: Própria (no external company) or Terceiro (the origin company is required)
  const provider = origin === 'third_party' ? text(f, 'provider_id') : ''
  if (origin !== 'own' && origin !== 'third_party') return go('erro:origem_invalida', NEW_TABLE)
  if (origin === 'third_party' && !isUuid(provider)) return go('erro:origem_invalida', NEW_TABLE)
  if (!isUuid(bank) || !isUuid(agreement) || !isLabel(name)) return go('erro:catalogo_invalido', NEW_TABLE)
  const org = ctx.membership.organization_id
  const ins = await ctx.supabase.from('organization_product_routes').insert({ organization_id: org, org_bank_id: bank, org_provider_id: provider || null, org_agreement_id: agreement, production_origin: origin, status: 'active' }).select('id').single()
  let routeId = ins.data?.id as string | undefined
  if (ins.error) {
    if (ins.error.code !== '23505') return go(comError(ins.error), NEW_TABLE)
    // the route already exists (same bank/agreement/provider): reuse it, several tables may hang on one route
    let q = ctx.supabase.from('organization_product_routes').select('id').eq('org_bank_id', bank).eq('org_agreement_id', agreement)
    q = provider ? q.eq('org_provider_id', provider) : q.is('org_provider_id', null)
    routeId = (await q.limit(1).maybeSingle()).data?.id
  }
  if (!routeId) return go('erro:inesperado', NEW_TABLE)
  const code = `t-${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`
  const tbl = await ctx.supabase.from('product_tables').insert({ organization_id: org, route_id: routeId, code, name, status: 'active' }).select('id').single()
  if (tbl.error || !tbl.data) return go(tbl.error ? comError(tbl.error) : 'erro:inesperado', NEW_TABLE)
  const ver = await ctx.supabase.from('product_table_versions').insert({ organization_id: org, product_table_id: tbl.data.id, version: 1, status: 'draft' })
  return ver.error ? go(comError(ver.error), NEW_TABLE) : go('ok:tabela_criada', `${PATH}/tabelas/${tbl.data.id}`)
}
