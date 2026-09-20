'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { classifyDbFeedback, feedbackUrl, isFeedbackCode, type FeedbackCode } from '@/lib/feedback'
import { isLabel } from '@/lib/catalog'
import { isUuid } from '@/lib/team'
import { IMPORT_ISSUE_TEXT, mapConditionRows, parseCoefficient, parseDelimited, parsePercent, parseRate, parseTerm, resolveShares, type Basis, type PolicyRef, type ShareInput } from '@/lib/commercial'
import { xlsxRows } from '@/lib/commercial-xlsx'
import { parseBulkRefusal } from '@/lib/commercial'

const PATH = '/app/comercial'
const RETURN_PATHS = new Set([PATH, `${PATH}/instituicoes`, `${PATH}/origens`, `${PATH}/convenios`, `${PATH}/grupos`])
const returnPath = (f: FormData) => { const p = String(f.get('return_to') ?? '').trim(); return RETURN_PATHS.has(p) ? p : PATH }
const go = (code: FeedbackCode, path = PATH): never => { revalidatePath(PATH); revalidatePath(path); revalidatePath('/app/configuracao'); return redirect(feedbackUrl(path, code)) }
const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim()
// The database authorizes every write (RLS + guard triggers + governed RPC); the role check here only fails early with a clear message.
const COM_CODES = ['condition_already_exists', 'invalid_shares', 'duplicate_group_share', 'commission_group_not_found', 'production_shares_exceed_received_commission', 'policy_not_found', 'policy_group_inactive', 'policy_group_must_use_received_basis', 'invalid_policy', 'policy_already_exists', 'invalid_term', 'coefficient_or_rate_required', 'invalid_received_commission', 'contract_type_not_found', 'condition_not_found', 'version_not_draft', 'national_template_not_available'] as const
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

export async function createCommissionGroup(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  // "kind" is a technical classification, not a required business decision. The UI now only asks the user for the group name and calculation basis.
  const name = text(f, 'name'), kind = text(f, 'kind') || 'other', basis = text(f, 'calculation_basis')
  if (!isLabel(name, 80) || !['broker', 'partner', 'referrer', 'employee', 'sales_team', 'counter', 'supervisor', 'manager', 'other'].includes(kind) || !['percent_of_production', 'percent_of_received_commission'].includes(basis)) return go('erro:catalogo_invalido', returnPath(f))
  const { error } = await ctx.supabase.from('commission_groups').insert({ organization_id: ctx.membership.organization_id, name, kind, calculation_basis: basis })
  return error ? go(comError(error), returnPath(f)) : go('ok:grupo_cadastrado', returnPath(f))
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
export async function createCommercialTable(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const bank = text(f, 'bank_id'), agreement = text(f, 'agreement_id'), name = text(f, 'name'), origin = text(f, 'production_origin')
  // Origem da Produção: Própria (no external company) or Terceiro (the origin company is required)
  const provider = origin === 'third_party' ? text(f, 'provider_id') : ''
  if (origin !== 'own' && origin !== 'third_party') return go('erro:origem_invalida')
  if (origin === 'third_party' && !isUuid(provider)) return go('erro:origem_invalida')
  if (!isUuid(bank) || !isUuid(agreement) || !isLabel(name)) return go('erro:catalogo_invalido')
  const org = ctx.membership.organization_id
  const ins = await ctx.supabase.from('organization_product_routes').insert({ organization_id: org, org_bank_id: bank, org_provider_id: provider || null, org_agreement_id: agreement, production_origin: origin, status: 'active' }).select('id').single()
  let routeId = ins.data?.id as string | undefined
  if (ins.error) {
    if (ins.error.code !== '23505') return go(comError(ins.error))
    // the route already exists (same bank/agreement/provider): reuse it, several tables may hang on one route
    let q = ctx.supabase.from('organization_product_routes').select('id').eq('org_bank_id', bank).eq('org_agreement_id', agreement)
    q = provider ? q.eq('org_provider_id', provider) : q.is('org_provider_id', null)
    routeId = (await q.limit(1).maybeSingle()).data?.id
  }
  if (!routeId) return go('erro:inesperado')
  const code = `t-${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`
  const tbl = await ctx.supabase.from('product_tables').insert({ organization_id: org, route_id: routeId, code, name, status: 'active' }).select('id').single()
  if (tbl.error || !tbl.data) return go(tbl.error ? comError(tbl.error) : 'erro:inesperado')
  const ver = await ctx.supabase.from('product_table_versions').insert({ organization_id: org, product_table_id: tbl.data.id, version: 1, status: 'draft' })
  return ver.error ? go(comError(ver.error)) : go('ok:tabela_criada')
}

export async function newDraftVersion(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const table_id = text(f, 'table_id')
  if (!isUuid(table_id)) return go('erro:catalogo_invalido')
  const { data: last } = await ctx.supabase.from('product_table_versions').select('version').eq('product_table_id', table_id).order('version', { ascending: false }).limit(1).maybeSingle()
  const { error } = await ctx.supabase.from('product_table_versions').insert({ organization_id: ctx.membership.organization_id, product_table_id: table_id, version: (last?.version ?? 0) + 1, status: 'draft' })
  return error ? go(comError(error)) : go('ok:versao_criada')
}

export async function publishCommercialVersion(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const id = text(f, 'version_id')
  if (!isUuid(id)) return go('erro:catalogo_invalido')
  const { error } = await ctx.supabase.rpc('publish_product_table_version', { p_version_id: id })
  return error ? go(comError(error)) : go('ok:versao_publicada')
}

type Ctx = NonNullable<Awaited<ReturnType<typeof manager>>>
const loadGroups = async (ctx: Ctx) => {
  const { data } = await ctx.supabase.from('commission_groups').select('id,name,calculation_basis').eq('is_active', true)
  return (data ?? []).map(g => ({ id: g.id as string, name: g.name as string, basis: g.calculation_basis as Basis }))
}

// A payout policy version (rate card: % of the commission RECEIVED per group), read for validation and the preview only; the database applies it again.
const loadPolicy = async (ctx: Ctx, versionId: string): Promise<PolicyRef | null> => {
  if (!isUuid(versionId)) return null
  const [v, items] = await Promise.all([
    ctx.supabase.from('payout_policy_versions').select('base_kind,discount_pct').eq('id', versionId).maybeSingle(),
    ctx.supabase.from('payout_policy_items').select('group_id,pct').eq('version_id', versionId),
  ])
  if (!v.data) return null
  return { baseKind: v.data.base_kind === 'net' ? 'net' : 'gross', discountPct: String(v.data.discount_pct), items: (items.data ?? []).map(i => ({ group_id: i.group_id as string, pct: String(i.pct) })) }
}

// New payout policy or a new version of an existing one. Versions are immutable: changing a policy never rewrites what earlier conditions used.
export async function savePayoutPolicy(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const policyId = text(f, 'policy_id'), name = text(f, 'name'), kind = text(f, 'base_kind')
  const discount = text(f, 'discount') === '' ? '0' : parsePercent(text(f, 'discount'))
  if ((policyId !== '' && !isUuid(policyId)) || (policyId === '' && !isLabel(name, 80)) || (kind !== 'gross' && kind !== 'net') || discount === null) return go('erro:com_invalid_policy')
  const groups = (await loadGroups(ctx)).filter(g => g.basis === 'percent_of_received_commission')
  const items: ShareInput[] = []
  for (const g of groups) {
    const raw = text(f, `p_${g.id}`)
    if (raw === '') continue
    const pct = parsePercent(raw)
    if (pct === null) return go('erro:com_invalid_policy')
    items.push({ group_id: g.id, pct })
  }
  const { error } = await ctx.supabase.rpc('save_payout_policy', {
    p_organization: ctx.membership.organization_id, p_name: policyId ? null : name, p_base_kind: kind, p_discount: kind === 'net' ? discount : '0', p_items: items, p_policy: policyId || null,
  })
  return error ? go(comError(error)) : go('ok:politica_salva')
}

// ONE form = the whole condition: Tipo de Contrato, prazo, coeficiente/taxa, comissão recebida, an optional payout policy and one percentage per commission group
// (blank = the policy value, or the group is not in this condition; a typed value overrides the policy for that group).
export async function saveCondition(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const version = text(f, 'version_id'), contractType = text(f, 'contract_type_id'), condition = text(f, 'condition_id'), policyVersion = text(f, 'policy_version_id')
  if (!isUuid(version) || !isUuid(contractType) || (condition !== '' && !isUuid(condition)) || (policyVersion !== '' && !isUuid(policyVersion))) return go('erro:catalogo_invalido')
  const term = parseTerm(text(f, 'term'))
  const coefficient = text(f, 'coefficient') === '' ? null : parseCoefficient(text(f, 'coefficient'))
  const rate = text(f, 'rate') === '' ? null : parseRate(text(f, 'rate'))
  const received = parsePercent(text(f, 'received'))
  if (term === null) return go('erro:com_invalid_term')
  if ((text(f, 'coefficient') !== '' && coefficient === null) || (text(f, 'rate') !== '' && rate === null) || (coefficient === null && rate === null)) return go('erro:com_coefficient_or_rate_required')
  if (received === null) return go('erro:com_invalid_received_commission')
  const groups = await loadGroups(ctx)
  const shares: ShareInput[] = []
  for (const g of groups) {
    const raw = text(f, `g_${g.id}`)
    if (raw === '') continue
    const pct = parsePercent(raw)
    if (pct === null) return go('erro:com_invalid_shares')
    shares.push({ group_id: g.id, pct })
  }
  const policy = policyVersion ? await loadPolicy(ctx, policyVersion) : undefined
  if (policyVersion && !policy) return go('erro:com_policy_not_found')
  const bad = resolveShares(groups, shares, received, policy ?? undefined).error
  if (bad) return go(`erro:com_${bad}` as FeedbackCode)
  const { error } = await ctx.supabase.rpc('save_commercial_condition', {
    p_version: version, p_contract_type: contractType, p_term: term, p_coefficient: coefficient, p_rate: rate, p_received: received, p_shares: shares, p_condition: condition || null,
    p_policy_version: policyVersion || null,
  })
  return error ? go(comError(error)) : go('ok:condicao_salva')
}

// CSV/XLSX with one column per commission group. The whole file is validated first (one bad line refuses everything); nothing is saved in "Validar" mode
// (preview: how many lines, which contract types). "Importar" then sends each line through the same governed RPC as the form, updating a condition that already
// exists for the same Tipo de Contrato + prazo (re-sending the same file is safe). A chosen payout policy fills every group the file leaves blank.
export async function importConditions(f: FormData) {
  const ctx = await manager(); if (!ctx) return go('erro:sem_permissao')
  const version = text(f, 'version_id'), file = f.get('file'), policyVersion = text(f, 'policy_version_id'), preview = text(f, 'mode') === 'preview'
  if (!isUuid(version) || (policyVersion !== '' && !isUuid(policyVersion))) return go('erro:catalogo_invalido')
  if (!(file instanceof File) || file.size === 0 || file.size > 1_048_576) return go('erro:import_arquivo')
  const buf = Buffer.from(await file.arrayBuffer())
  let rows: string[][]
  try {
    const isXlsx = /\.xlsx$/i.test(file.name) || (buf[0] === 0x50 && buf[1] === 0x4b)
    rows = isXlsx ? await xlsxRows(buf) : parseDelimited(buf.toString('utf-8'))
  } catch { return go('erro:import_arquivo') }
  const [groups, types, existing, policy] = await Promise.all([
    loadGroups(ctx),
    ctx.supabase.from('contract_types').select('id,name,tech_key').eq('is_active', true),
    ctx.supabase.from('commercial_conditions').select('id,contract_type_id,term').eq('product_table_version_id', version),
    policyVersion ? loadPolicy(ctx, policyVersion) : Promise.resolve(undefined),
  ])
  if (policyVersion && !policy) return go('erro:com_policy_not_found')
  const { conditions, issues } = mapConditionRows(rows, { groups, contractTypes: (types.data ?? []) as { id: string; name: string; tech_key: string }[], policy: policy ?? undefined })
  if (issues.length) {
    const first = issues[0]
    const code = Object.prototype.hasOwnProperty.call(IMPORT_ISSUE_TEXT, first.code) ? first.code : 'invalid_shares'
    revalidatePath(PATH)
    return redirect(`${feedbackUrl(PATH, 'erro:import_invalido')}&l=${first.line}&c=${code}&n=${issues.length}`)
  }
  const byKey = new Map((existing.data ?? []).map(c => [`${c.contract_type_id}|${c.term}`, c.id as string]))
  if (preview) {
    const updates = conditions.filter(c => byKey.has(`${c.contractTypeId}|${c.term}`)).length
    revalidatePath(PATH)
    return redirect(`${feedbackUrl(PATH, 'ok:previa_validada')}&n=${conditions.length}&u=${updates}`)
  }
  // Atomic path: ONE database call = one transaction (all lines or none). Numbers travel as strings, never floats.
  const payload = conditions.map(c => ({ line: c.line, contract_type_id: c.contractTypeId, term: c.term, coefficient: c.coefficient, rate: c.rate, received: c.received, shares: c.shares }))
  const bulk = await ctx.supabase.rpc('import_commercial_conditions', { p_version: version, p_rows: payload, p_policy_version: policyVersion || null })
  if (!bulk.error) return go('ok:condicoes_importadas')
  const refused = parseBulkRefusal(bulk.error)
  if (refused) {
    revalidatePath(PATH)
    const code = Object.prototype.hasOwnProperty.call(IMPORT_ISSUE_TEXT, refused[0].code) ? refused[0].code : 'unexpected'
    return redirect(`${feedbackUrl(PATH, 'erro:import_invalido')}&l=${refused[0].line}&c=${code}&n=${refused.length}`)
  }
  // Until the bulk migration is applied the RPC does not exist: keep working with the previous line-by-line path (NOT atomic; re-sending the file is safe).
  if (bulk.error.code !== 'PGRST202') return go(comError(bulk.error))
  for (const c of conditions) {
    const { error } = await ctx.supabase.rpc('save_commercial_condition', {
      p_version: version, p_contract_type: c.contractTypeId, p_term: c.term, p_coefficient: c.coefficient, p_rate: c.rate, p_received: c.received, p_shares: c.shares,
      p_condition: byKey.get(`${c.contractTypeId}|${c.term}`) ?? null, p_policy_version: policyVersion || null,
    })
    if (error) return go(comError(error))
  }
  return go('ok:condicoes_importadas')
}
