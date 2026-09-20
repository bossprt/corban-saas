import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { IMPORT_ISSUE_TEXT } from '@/lib/commercial'
import { createAgreement, createBank, createCommercialTable, createCommissionGroup, createProvider, enableAgreementTemplate, importConditions, newDraftVersion, publishCommercialVersion, saveCondition, setActive } from './actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
const VSTATUS: Record<string, string> = { draft: 'Rascunho', published: 'Publicada', superseded: 'Substituída', expired: 'Expirada' }
const PROVIDER_TYPE: Record<string, string> = { bank_direct: 'Banco direto', master: 'Master', promotora: 'Promotora', other: 'Outro' }
const GROUP_KIND: Record<string, string> = { broker: 'Corretor', partner: 'Parceiro', referrer: 'Indicador', employee: 'Funcionário', sales_team: 'Equipe de vendas', counter: 'Balcão', supervisor: 'Supervisor', manager: 'Gerente', other: 'Outro' }
const BASIS: Record<string, string> = { percent_of_production: '% sobre a produção', percent_of_received_commission: '% sobre a comissão recebida' }
const show = (v: number | string | null | undefined) => (v === null || v === undefined ? '—' : String(v))

type Group = { id: string; name: string; calculation_basis: string }
type Condition = { id: string; contract_type_id: string; term: number; coefficient: number | null; rate: number | null }

function ActiveToggle({ kind, id, active }: { kind: string; id: string; active: boolean }) {
  return <form action={setActive} className="inline"><input type="hidden" name="kind" value={kind} /><input type="hidden" name="id" value={id} /><input type="hidden" name="active" value={active ? 'false' : 'true'} />
    <button className="text-xs text-slate-400 underline">{active ? 'Desativar' : 'Reativar'}</button></form>
}

function ConditionForm({ versionId, contractTypes, groups, cond, received, shares }: {
  versionId: string; contractTypes: { id: string; name: string }[]; groups: Group[]; cond?: Condition; received?: number | null; shares?: Map<string, number>
}) {
  return <form action={saveCondition} className="grid gap-2 md:grid-cols-4">
    <input type="hidden" name="version_id" value={versionId} />{cond && <input type="hidden" name="condition_id" value={cond.id} />}
    <select required name="contract_type_id" defaultValue={cond?.contract_type_id ?? ''} className={field}><option value="" disabled>Tipo de Contrato</option>{contractTypes.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select>
    <input required name="term" inputMode="numeric" defaultValue={cond?.term ?? ''} placeholder="Prazo (meses)" className={field} />
    <input name="coefficient" inputMode="decimal" defaultValue={cond?.coefficient ?? ''} placeholder="Coeficiente" className={field} />
    <input name="rate" inputMode="decimal" defaultValue={cond?.rate ?? ''} placeholder="Taxa (%)" className={field} />
    <input required name="received" inputMode="decimal" defaultValue={received ?? ''} placeholder="Comissão recebida (%)" className={`${field} md:col-span-4`} />
    {groups.map(g => <label key={g.id} className="text-xs text-slate-400">{g.name} <span className="text-slate-500">({BASIS[g.calculation_basis] ?? g.calculation_basis})</span>
      <input name={`g_${g.id}`} inputMode="decimal" defaultValue={shares?.get(g.id) ?? ''} placeholder="% (vazio = não participa)" className={`${field} mt-1 w-full`} /></label>)}
    <SubmitButton className={`${ghost} md:col-span-4 md:justify-self-end`} pendingText="Salvando...">{cond ? 'Salvar alterações' : 'Adicionar condição'}</SubmitButton>
  </form>
}

export default async function CommercialPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const { supabase, membership } = await requireAppContext()
  const sp = await searchParams
  const canEdit = atLeast(membership.role, 'manager')
  const seeCommission = canViewCommission(membership.role)
  if (!atLeast(membership.role, 'supervisor')) return <section><h1 className="text-3xl font-semibold">Modelo comercial</h1>
    <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">O modelo comercial é restrito a supervisor, gerente e administrador.</p></section>

  const [banks, providers, agreements, templates, groups, contractTypes, routes, tables, versions, conditions, commissions, shares] = await Promise.all([
    supabase.from('organization_banks').select('id,name,is_active').order('name'),
    supabase.from('organization_providers').select('id,name,provider_type,is_active').order('name'),
    supabase.from('organization_agreements').select('id,name,template_id,is_active').order('name'),
    supabase.from('national_agreement_templates').select('id,kind,name,uf').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,kind,calculation_basis,is_active').order('sort_order').order('name'),
    supabase.from('contract_types').select('id,name').eq('is_active', true).order('sort_order'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_provider_id,org_agreement_id,status').not('org_bank_id', 'is', null),
    supabase.from('product_tables').select('id,route_id,name,status').order('name'),
    supabase.from('product_table_versions').select('id,product_table_id,version,status').order('version', { ascending: false }),
    supabase.from('commercial_conditions').select('id,product_table_version_id,contract_type_id,term,coefficient,rate').order('term'),
    seeCommission ? supabase.from('commercial_condition_commissions').select('condition_id,received_commission_pct') : Promise.resolve({ data: [] as { condition_id: string; received_commission_pct: number }[] }),
    seeCommission ? supabase.from('commercial_condition_shares').select('condition_id,group_id,share_pct') : Promise.resolve({ data: [] as { condition_id: string; group_id: string; share_pct: number }[] }),
  ])
  const nameOf = (rows: { id: string; name: string }[] | null) => new Map((rows ?? []).map(r => [r.id, r.name]))
  const bankN = nameOf(banks.data), provN = nameOf(providers.data), agrN = nameOf(agreements.data), typeN = nameOf(contractTypes.data), groupN = nameOf(groups.data)
  const enabled = new Set((agreements.data ?? []).map(a => a.template_id).filter(Boolean))
  const govs = (templates.data ?? []).filter(t => t.kind === 'state_government' && !enabled.has(t.id))
  const halls = (templates.data ?? []).filter(t => t.kind === 'capital_city_hall' && !enabled.has(t.id))
  const activeGroups = (groups.data ?? []).filter(g => g.is_active) as Group[]
  const routeLabel = new Map((routes.data ?? []).map(r => [r.id, `${bankN.get(r.org_bank_id) ?? 'Banco'} · ${agrN.get(r.org_agreement_id) ?? 'Convênio'}${r.org_provider_id ? ` · ${provN.get(r.org_provider_id) ?? 'Provedor'}` : ''}`]))
  const v3Tables = (tables.data ?? []).filter(t => routeLabel.has(t.route_id))
  const receivedBy = new Map((commissions.data ?? []).map(c => [c.condition_id, c.received_commission_pct]))
  const sharesBy = new Map<string, Map<string, number>>()
  for (const s of shares.data ?? []) { if (!sharesBy.has(s.condition_id)) sharesBy.set(s.condition_id, new Map()); sharesBy.get(s.condition_id)!.set(s.group_id, s.share_pct) }
  const importIssue = typeof sp.c === 'string' && Object.prototype.hasOwnProperty.call(IMPORT_ISSUE_TEXT, sp.c) ? IMPORT_ISSUE_TEXT[sp.c] : null
  const importLine = typeof sp.l === 'string' && /^\d{1,5}$/.test(sp.l) ? sp.l : null

  return <section>
    <h1 className="text-3xl font-semibold">Modelo comercial</h1>
    <p className="mt-2 text-sm text-slate-400">Banco → Convênio → Tabela → Tipo de Contrato → Prazo → Coeficiente/Taxa → Comissão recebida → Grupos de comissão. Tudo é da sua organização; os códigos técnicos são gerados pelo sistema.</p>
    {!canEdit && <p className="mt-3 rounded-xl border border-slate-800 p-3 text-xs text-slate-400">Seu perfil só consulta. Cadastros e condições são de gerente/administrador.</p>}
    {importIssue && <p role="alert" className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-200">Importação recusada{importLine ? ` — linha ${importLine}` : ''}: {importIssue}{typeof sp.n === 'string' && /^\d{1,5}$/.test(sp.n) && Number(sp.n) > 1 ? ` (${sp.n} problemas no total; corrija e envie de novo)` : ''}</p>}

    <h2 className="mt-8 text-xl font-semibold">1. Bancos e provedores</h2>
    <div className={`${card} mt-3 space-y-3 text-sm`}>
      <div><strong>Bancos</strong>{!banks.data?.length ? <p className="text-slate-400">Nenhum banco ainda.</p> : <ul className="mt-1 space-y-1">{banks.data.map(b => <li key={b.id}>{b.name} {!b.is_active && <span className="text-xs text-slate-500">(inativo)</span>} {canEdit && <ActiveToggle kind="bank" id={b.id} active={b.is_active} />}</li>)}</ul>}
        {canEdit && <form action={createBank} className="mt-2 flex flex-wrap gap-2"><input required name="name" maxLength={120} placeholder="Nome do banco" className={field} /><SubmitButton className={btn}>Cadastrar banco</SubmitButton></form>}</div>
      <div><strong>Provedores / masters</strong> <span className="text-xs text-slate-500">(opcional)</span>{!providers.data?.length ? <p className="text-slate-400">Nenhum provedor.</p> : <ul className="mt-1 space-y-1">{providers.data.map(p => <li key={p.id}>{p.name} <span className="text-xs text-slate-500">· {PROVIDER_TYPE[p.provider_type] ?? p.provider_type}{!p.is_active ? ' · inativo' : ''}</span> {canEdit && <ActiveToggle kind="provider" id={p.id} active={p.is_active} />}</li>)}</ul>}
        {canEdit && <form action={createProvider} className="mt-2 flex flex-wrap gap-2"><input required name="name" maxLength={120} placeholder="Nome do provedor" className={field} />
          <select name="provider_type" defaultValue="master" className={field}>{Object.entries(PROVIDER_TYPE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select><SubmitButton className={btn}>Cadastrar provedor</SubmitButton></form>}</div>
    </div>

    <h2 className="mt-8 text-xl font-semibold">2. Convênios</h2>
    <div className={`${card} mt-3 space-y-3 text-sm`}>
      <p className="text-xs text-slate-500">Convênios nacionais (governos e prefeituras de capitais) não pertencem a nenhum banco: habilite os que a sua organização trabalha.</p>
      {!agreements.data?.length ? <p className="text-slate-400">Nenhum convênio habilitado.</p> : <ul className="space-y-1">{agreements.data.map(a => <li key={a.id}>{a.name} <span className="text-xs text-slate-500">· {a.template_id ? 'nacional' : 'próprio'}{!a.is_active ? ' · inativo' : ''}</span> {canEdit && <ActiveToggle kind="agreement" id={a.id} active={a.is_active} />}</li>)}</ul>}
      {canEdit && <div className="grid gap-2 md:grid-cols-2">
        <form action={enableAgreementTemplate} className="flex gap-2"><select required name="template_id" defaultValue="" className={`${field} flex-1`}><option value="" disabled>Governo estadual / DF ({govs.length})</option>{govs.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={btn}>Habilitar</SubmitButton></form>
        <form action={enableAgreementTemplate} className="flex gap-2"><select required name="template_id" defaultValue="" className={`${field} flex-1`}><option value="" disabled>Prefeitura de capital ({halls.length})</option>{halls.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select><SubmitButton className={btn}>Habilitar</SubmitButton></form>
        <form action={createAgreement} className="flex gap-2 md:col-span-2"><input required name="name" maxLength={120} placeholder="Outro convênio (prefeitura, órgão, empresa...)" className={`${field} flex-1`} /><SubmitButton className={ghost}>Cadastrar convênio próprio</SubmitButton></form>
      </div>}
    </div>

    <h2 className="mt-8 text-xl font-semibold">3. Grupos de comissão</h2>
    <div className={`${card} mt-3 space-y-3 text-sm`}>
      <p className="text-xs text-slate-500">Cada grupo diz como o percentual da condição é lido: sobre a produção ou sobre a comissão que a empresa recebe. Gerente e supervisor são grupos opcionais.</p>
      {!groups.data?.length ? <p className="text-slate-400">Nenhum grupo ainda.</p> : <ul className="space-y-1">{groups.data.map(g => <li key={g.id}>{g.name} <span className="text-xs text-slate-500">· {GROUP_KIND[g.kind] ?? g.kind} · {BASIS[g.calculation_basis] ?? g.calculation_basis}{!g.is_active ? ' · inativo' : ''}</span> {canEdit && <ActiveToggle kind="group" id={g.id} active={g.is_active} />}</li>)}</ul>}
      {canEdit && <form action={createCommissionGroup} className="flex flex-wrap gap-2"><input required name="name" maxLength={80} placeholder="Nome do grupo" className={field} />
        <select name="kind" defaultValue="broker" className={field}>{Object.entries(GROUP_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        <select name="calculation_basis" defaultValue="percent_of_production" className={field}>{Object.entries(BASIS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select><SubmitButton className={btn}>Cadastrar grupo</SubmitButton></form>}
    </div>

    <h2 className="mt-8 text-xl font-semibold">4. Tabelas e condições</h2>
    <div className="mt-3 space-y-3">
      {!v3Tables.length && <p className={`${card} text-sm text-slate-400`}>Nenhuma tabela ainda. Escolha banco e convênio, dê um nome e crie a tabela.</p>}
      {v3Tables.map(t => <div key={t.id} className={card}>
        <div className="font-medium">{t.name} <span className="text-xs text-slate-500">· {routeLabel.get(t.route_id)}</span></div>
        {(versions.data ?? []).filter(v => v.product_table_id === t.id).map(v => {
          const conds = (conditions.data ?? []).filter(c => c.product_table_version_id === v.id) as (Condition & { product_table_version_id: string })[]
          return <div key={v.id} className="mt-3 rounded-xl border border-slate-800 p-3">
            <div className="flex flex-wrap items-center gap-3 text-sm"><span>v{v.version} · {VSTATUS[v.status] ?? v.status} · {conds.length} condição(ões)</span>
              {v.status === 'draft' && canEdit && <form action={publishCommercialVersion}><input type="hidden" name="version_id" value={v.id} /><SubmitButton className="rounded border border-emerald-500/60 px-2 py-1 text-xs text-emerald-300" pendingText="Publicando...">Publicar</SubmitButton></form>}</div>
            <ul className="mt-2 space-y-2 text-sm">{conds.map(c => <li key={c.id}>
              <span>{typeN.get(c.contract_type_id) ?? 'Tipo'} · {c.term} meses · coeficiente {show(c.coefficient)} · taxa {show(c.rate)}
                {seeCommission && <> · comissão recebida {show(receivedBy.get(c.id))}%{[...(sharesBy.get(c.id) ?? [])].map(([gid, pct]) => <span key={gid} className="ml-2 text-xs text-slate-400">{groupN.get(gid) ?? 'grupo'} {pct}%</span>)}</>}</span>
              {v.status === 'draft' && canEdit && <details className="mt-1"><summary className="cursor-pointer text-xs text-slate-400">Editar</summary><div className="mt-2"><ConditionForm versionId={v.id} contractTypes={contractTypes.data ?? []} groups={activeGroups} cond={c} received={receivedBy.get(c.id)} shares={sharesBy.get(c.id)} /></div></details>}
            </li>)}</ul>
            {v.status === 'draft' && canEdit && <div className="mt-3 space-y-3">
              {!activeGroups.length && <p className="text-xs text-amber-200">Cadastre pelo menos um grupo de comissão para registrar as participações.</p>}
              <ConditionForm versionId={v.id} contractTypes={contractTypes.data ?? []} groups={activeGroups} />
              <form action={importConditions} className="flex flex-wrap items-center gap-2 text-xs text-slate-400"><input type="hidden" name="version_id" value={v.id} /><input required type="file" name="file" accept=".csv,.xlsx,text/csv" className="text-xs" />
                <SubmitButton className={ghost} pendingText="Importando...">Importar CSV/XLSX</SubmitButton>
                <span>Colunas: Tipo de Contrato, Prazo, Coeficiente, Taxa, Comissão recebida e uma coluna por grupo ({activeGroups.map(g => g.name).join(', ') || 'nenhum grupo'}).</span></form></div>}
          </div>
        })}
        {canEdit && <form action={newDraftVersion} className="mt-3"><input type="hidden" name="table_id" value={t.id} /><SubmitButton className={ghost}>Nova versão (rascunho)</SubmitButton></form>}
      </div>)}
      {canEdit && <form action={createCommercialTable} className={`${card} grid gap-2 md:grid-cols-4`}>
        <select required name="bank_id" defaultValue="" className={field}><option value="" disabled>Banco</option>{(banks.data ?? []).filter(b => b.is_active).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select required name="agreement_id" defaultValue="" className={field}><option value="" disabled>Convênio</option>{(agreements.data ?? []).filter(a => a.is_active).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select>
        <select name="provider_id" defaultValue="" className={field}><option value="">Sem provedor</option>{(providers.data ?? []).filter(p => p.is_active).map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
        <input required name="name" maxLength={120} placeholder="Nome da tabela" className={field} />
        <SubmitButton className={`${btn} md:col-span-4 md:justify-self-end`}>Criar tabela</SubmitButton>
        <p className="text-xs text-slate-500 md:col-span-4">A simulação usa a versão PUBLICADA: valor × coeficiente = parcela. Comissão nunca aparece para o operador.</p>
      </form>}
    </div>
    <p className="mt-8 text-xs text-slate-500">Catálogo anterior (rotas por produto e modalidade) continua disponível em <Link href="/app/catalogo" className="underline">Catálogo</Link> para o que já existe.</p>
  </section>
}
