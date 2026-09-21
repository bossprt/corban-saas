import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { IMPORT_ISSUE_TEXT } from '@/lib/commercial'
import { effectiveContractTypes } from '@/lib/contract-types'
import { createCommercialTable, importConditions, newDraftVersion, publishCommercialVersion, saveCondition } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
const VSTATUS: Record<string,string> = { draft:'Rascunho', published:'Publicada', superseded:'Substituída', expired:'Expirada' }
const BASIS: Record<string,string> = {
  percent_of_production:'% direto sobre a operação',
  percent_of_received_commission:'% da comissão recebida',
}
const show = (v: number | string | null | undefined) => (v === null || v === undefined ? '—' : String(v))
const showPct = (v: number | string | null | undefined) => {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  return Number.isFinite(n) ? n.toFixed(2) : '—'
}

type Group = { id:string; name:string; calculation_basis:string }
type PolicyOpt = { versionId:string; name:string }
type Condition = { id:string; contract_type_id:string; term:number; term_min:number; term_max:number; coefficient:number|null; rate:number|null }

function ConditionForm({ versionId, contractTypes, groups, policies, cond, received, shares, policyVersion }: {
  versionId:string; contractTypes:{id:string;name:string}[]; groups:Group[]; policies:PolicyOpt[]; cond?:Condition; received?:number|null; shares?:Map<string,number>; policyVersion?:string|null
}) {
  return <form action={saveCondition} className="grid gap-2 md:grid-cols-4">
    <input type="hidden" name="version_id" value={versionId} />{cond && <input type="hidden" name="condition_id" value={cond.id} />}
    <select required name="contract_type_id" defaultValue={cond?.contract_type_id ?? ''} className={field}><option value="" disabled>Tipo de Contrato</option>{contractTypes.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select>
    <input required name="term_min" inputMode="numeric" defaultValue={cond?.term_min ?? cond?.term ?? ''} placeholder="Prazo inicial" className={field} />
    <input required name="term_max" inputMode="numeric" defaultValue={cond?.term_max ?? cond?.term ?? ''} placeholder="Prazo final" className={field} />
    <input name="coefficient" inputMode="decimal" defaultValue={cond?.coefficient ?? ''} placeholder="Coeficiente" className={field} />
    <input name="rate" inputMode="decimal" defaultValue={cond?.rate ?? ''} placeholder="Taxa (%)" className={field} />
    <input required name="received" inputMode="decimal" defaultValue={received ?? ''} placeholder="Comissão que a empresa recebe (%)" className={`${field} md:col-span-2`} />
    <select name="policy_version_id" defaultValue={policyVersion ?? ''} className={`${field} md:col-span-2`}><option value="">Sem regra padrão</option>{policies.map(p => <option key={p.versionId} value={p.versionId}>Regra padrão: {p.name}</option>)}</select>
    {groups.map(g => <label key={g.id} className="text-xs text-slate-400">{g.name} <span className="text-slate-500">({BASIS[g.calculation_basis] ?? g.calculation_basis})</span><input name={`g_${g.id}`} inputMode="decimal" defaultValue={shares?.get(g.id) ?? ''} placeholder={policies.length ? '% (vazio = regra padrão / não participa)' : '% (vazio = não participa)'} className={`${field} mt-1 w-full`} /></label>)}
    <SubmitButton className={`${ghost} md:col-span-4 md:justify-self-end`} pendingText="Salvando...">{cond ? 'Salvar alterações' : 'Adicionar condição'}</SubmitButton>
  </form>
}

export default async function TablesPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const { supabase, membership } = await requireAppContext()
  const sp = await searchParams
  const canEdit = atLeast(membership.role, 'manager')
  const seeCommission = canViewCommission(membership.role)
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>

  const [banks, providers, agreements, groups, contractTypes, contractTypeSettings, routes, tables, versionsQ, polRows, polVersions] = await Promise.all([
    supabase.from('organization_banks').select('id,name,is_active').order('name'),
    supabase.from('organization_providers').select('id,name,is_active').order('name'),
    supabase.from('organization_agreements').select('id,name,is_active').order('name'),
    supabase.from('commission_groups').select('id,name,calculation_basis,is_active').order('sort_order').order('name'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status').not('org_bank_id','is',null),
    supabase.from('product_tables').select('id,route_id,name,status').order('name'),
    supabase.from('product_table_versions').select('id,product_table_id,version,status,effective_from,effective_until').order('version',{ascending:false}),
    supabase.from('payout_policies').select('id,name,is_active').order('name'),
    supabase.from('payout_policy_versions').select('id,policy_id,version').order('version',{ascending:false}),
  ])

  const versions=(versionsQ.data ?? []) as {id:string;product_table_id:string;version:number;status:string;effective_from:string|null;effective_until:string|null}[]

  const enabledContractTypes=effectiveContractTypes((contractTypes.data ?? []) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[], (contractTypeSettings.data ?? []) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[], 'commission')
  const nameOf = (rows:{id:string;name:string}[]|null) => new Map((rows ?? []).map(r => [r.id,r.name]))
  const bankN=nameOf(banks.data), provN=nameOf(providers.data), agrN=nameOf(agreements.data), typeN=nameOf(enabledContractTypes)
  const routeMeta=new Map((routes.data ?? []).map(r=>{
    const bank=bankN.get(r.org_bank_id) ?? 'Instituição'
    const agreement=agrN.get(r.org_agreement_id) ?? 'Convênio'
    const provider=r.production_origin==='third_party'
      ? (provN.get(r.org_provider_id) ?? 'Terceiro')
      : 'Próprio / Smart'
    return [r.id,{bank,agreement,provider,productionOrigin:r.production_origin ?? 'own'}]
  }))
  const allCommercialTables=(tables.data ?? []).filter(t => routeMeta.has(t.route_id))

  const q=typeof sp.q==='string'?sp.q.trim().toLocaleLowerCase('pt-BR'):''
  const bankFilter=typeof sp.bank==='string'?sp.bank:''
  const providerFilter=typeof sp.provider==='string'?sp.provider:''
  const agreementFilter=typeof sp.agreement==='string'?sp.agreement:''
  const statusFilter=typeof sp.status==='string'?sp.status:'current'
  const now=new Date()

  const currentVersionFor=(tableId:string)=>versions.find(v=>{
    if(v.product_table_id!==tableId||v.status!=='published')return false
    const from=v.effective_from?new Date(v.effective_from):new Date(0)
    const until=v.effective_until?new Date(v.effective_until):null
    return from<=now&&(!until||now<until)
  })
  const hasDraft=(tableId:string)=>versions.some(v=>v.product_table_id===tableId&&v.status==='draft')

  const v3Tables=allCommercialTables.filter(t=>{
    const meta=routeMeta.get(t.route_id)!
    if(bankFilter&&meta.bank!==bankFilter)return false
    if(providerFilter&&meta.provider!==providerFilter)return false
    if(agreementFilter&&meta.agreement!==agreementFilter)return false
    if(statusFilter==='current'&&!currentVersionFor(t.id))return false
    if(statusFilter==='draft'&&!hasDraft(t.id))return false
    if(statusFilter==='inactive'&&t.status==='active')return false
    if(q){
      const hay=[t.name,meta.bank,meta.provider,meta.agreement].join(' ').toLocaleLowerCase('pt-BR')
      if(!hay.includes(q))return false
    }
    return true
  })

  const grouped=new Map<string,Map<string,Map<string,typeof v3Tables>>>()
  for(const t of v3Tables){
    const meta=routeMeta.get(t.route_id)!
    if(!grouped.has(meta.bank))grouped.set(meta.bank,new Map())
    const byProvider=grouped.get(meta.bank)!
    if(!byProvider.has(meta.provider))byProvider.set(meta.provider,new Map())
    const byAgreement=byProvider.get(meta.provider)!
    if(!byAgreement.has(meta.agreement))byAgreement.set(meta.agreement,[])
    byAgreement.get(meta.agreement)!.push(t)
  }

  const bankOptions=[...new Set(allCommercialTables.map(t=>routeMeta.get(t.route_id)!.bank))].sort((a,b)=>a.localeCompare(b,'pt-BR'))
  const providerOptions=[...new Set(allCommercialTables.map(t=>routeMeta.get(t.route_id)!.provider))].sort((a,b)=>a.localeCompare(b,'pt-BR'))
  const agreementOptions=[...new Set(allCommercialTables.map(t=>routeMeta.get(t.route_id)!.agreement))].sort((a,b)=>a.localeCompare(b,'pt-BR'))

  const visibleTableIds=new Set(v3Tables.map(t=>t.id))
  const visibleVersions=versions.filter(v=>{
    if(!visibleTableIds.has(v.product_table_id)) return false
    if(statusFilter==='all') return true
    if(statusFilter==='draft') return v.status==='draft'
    if(statusFilter==='inactive') return true
    const from=v.effective_from?new Date(v.effective_from):new Date(0)
    const until=v.effective_until?new Date(v.effective_until):null
    return v.status==='draft'||(v.status==='published'&&from<=now&&(!until||now<until))
  })
  const visibleVersionIds=visibleVersions.map(v=>v.id)

  const emptyConditions:{id:string;product_table_version_id:string;contract_type_id:string;term:number;term_min:number;term_max:number;coefficient:number|null;rate:number|null}[]=[]
  const conditionsQ=visibleVersionIds.length
    ? await supabase.from('commercial_conditions')
        .select('id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate')
        .in('product_table_version_id',visibleVersionIds)
        .order('term_min')
    : {data:emptyConditions,error:null}
  if(conditionsQ.error) throw conditionsQ.error
  const conditions=(conditionsQ.data ?? []) as typeof emptyConditions
  const conditionIds=conditions.map(x=>x.id)

  const [commissionsQ,componentsQ,sharesQ]=conditionIds.length&&seeCommission
    ? await Promise.all([
        supabase.from('commercial_condition_commissions').select('condition_id,received_commission_pct,policy_version_id').in('condition_id',conditionIds),
        supabase.from('commercial_condition_components').select('condition_id,calculation_base,component_type_id').in('condition_id',conditionIds),
        supabase.from('commercial_condition_shares').select('condition_id,group_id,share_pct,effective_pct,source').in('condition_id',conditionIds),
      ])
    : [{data:[]},{data:[]},{data:[]}]
  const commissions=(commissionsQ.data ?? []) as {condition_id:string;received_commission_pct:number;policy_version_id:string|null}[]
  const components=(componentsQ.data ?? []) as {condition_id:string;calculation_base:string|null;component_type_id:string}[]
  const shares=(sharesQ.data ?? []) as {condition_id:string;group_id:string;share_pct:number;effective_pct:number;source:string}[]

  const activeGroups=(groups.data ?? []).filter(g => g.is_active) as Group[]
  const receivedBy=new Map(commissions.map(c => [c.condition_id,c.received_commission_pct]))
  const policyOf=new Map(commissions.map(c => [c.condition_id,c.policy_version_id]))
  const baseBy=new Map<string,string>()
  for(const x of components) if(x.calculation_base && !baseBy.has(x.condition_id)) baseBy.set(x.condition_id,x.calculation_base)
  const sharesBy=new Map<string,Map<string,number>>()
  const effectiveBy=new Map<string,Map<string,number>>()
  for (const s of shares) {
    if (s.source !== 'policy') { if (!sharesBy.has(s.condition_id)) sharesBy.set(s.condition_id,new Map()); sharesBy.get(s.condition_id)!.set(s.group_id,s.share_pct) }
    if (!effectiveBy.has(s.condition_id)) effectiveBy.set(s.condition_id,new Map())
    effectiveBy.get(s.condition_id)!.set(s.group_id,s.effective_pct)
  }
  const policyOpts:PolicyOpt[]=(polRows.data ?? []).filter(p=>p.is_active).map(p => {
    const latest=(polVersions.data ?? []).find(v=>v.policy_id===p.id)
    return latest ? {versionId:latest.id,name:p.name} : null
  }).filter((p):p is PolicyOpt=>Boolean(p))
  const importIssue = typeof sp.c === 'string' && Object.prototype.hasOwnProperty.call(IMPORT_ISSUE_TEXT,sp.c) ? IMPORT_ISSUE_TEXT[sp.c] : null
  const importLine = typeof sp.l === 'string' && /^\d{1,5}$/.test(sp.l) ? sp.l : null

  const renderTable=(t:(typeof v3Tables)[number])=>{
    const tableVersions=visibleVersions.filter(v=>v.product_table_id===t.id)
    const current=currentVersionFor(t.id)
    const drafts=tableVersions.filter(v=>v.status==='draft').length
    return <details key={t.id} className="rounded-xl border border-slate-800 bg-slate-950/40">
      <summary className="cursor-pointer list-none px-4 py-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <span className="font-medium">{t.name}</span>
            <span className="ml-2 text-xs text-slate-500">{current?'Vigente':'Sem versão vigente'}{drafts?' · '+drafts+' rascunho(s)':''}</span>
          </div>
          <span className="text-xs text-slate-500">Abrir tabela</span>
        </div>
      </summary>
      <div className="border-t border-slate-800 p-4">
        {tableVersions.map(v => {
          const conds=conditions.filter(c=>c.product_table_version_id===v.id) as (Condition & {product_table_version_id:string})[]
          return <div key={v.id} className="mt-2 rounded-xl border border-slate-800 p-3 first:mt-0">
            <div className="flex flex-wrap items-center gap-3 text-sm">
              <span>v{v.version} · {VSTATUS[v.status] ?? v.status} · {conds.length} condição(ões)</span>
              {v.effective_from&&<span className="text-xs text-slate-500">início {new Date(v.effective_from).toLocaleDateString('pt-BR',{timeZone:'UTC'})}</span>}
              {v.effective_until&&<span className="text-xs text-slate-500">fim {new Date(v.effective_until).toLocaleDateString('pt-BR',{timeZone:'UTC'})}</span>}
              {v.status==='draft' && canEdit && <form action={publishCommercialVersion}><input type="hidden" name="version_id" value={v.id}/><SubmitButton className="rounded border border-emerald-500/60 px-2 py-1 text-xs text-emerald-300" pendingText="Publicando...">Publicar</SubmitButton></form>}
            </div>
            <div className="mt-3 overflow-x-auto">
              <table className="w-full min-w-[1180px] text-left text-xs">
                <thead className="text-slate-500"><tr>
                  <th className="py-2 pr-4">Tipo</th><th className="pr-4">Prazo inicial</th><th className="pr-4">Prazo final</th><th className="pr-4">Coef.</th><th className="pr-4">Taxa</th>
                  {seeCommission && <><th className="pr-4">Comissão empresa</th><th className="pr-4">Base</th>{activeGroups.map(g=><th key={g.id} className="pr-4 whitespace-nowrap">{g.name}</th>)}</>}
                </tr></thead>
                <tbody>{conds.map(c => <tr key={c.id} className="border-t border-slate-800 align-top">
                  <td className="py-2 pr-4 whitespace-nowrap">{typeN.get(c.contract_type_id) ?? 'Tipo'}</td>
                  <td className="pr-4 whitespace-nowrap">{c.term_min}</td>
                  <td className="pr-4 whitespace-nowrap">{c.term_max}</td>
                  <td className="pr-4 whitespace-nowrap">{show(c.coefficient)}</td>
                  <td className="pr-4 whitespace-nowrap">{showPct(c.rate)}%</td>
                  {seeCommission && <>
                    <td className="pr-4 whitespace-nowrap font-medium">{showPct(receivedBy.get(c.id))}%</td>
                    <td className="pr-4 whitespace-nowrap">{baseBy.get(c.id) ?? '—'}</td>
                    {activeGroups.map(g=>{const effective=effectiveBy.get(c.id)?.get(g.id);return <td key={g.id} className="pr-4 whitespace-nowrap">{effective===undefined?'—':showPct(effective)+'%'}</td>})}
                  </>}
                </tr>)}</tbody>
              </table>
            </div>
            {v.status==='draft' && canEdit && <div className="mt-4 grid gap-3 lg:grid-cols-2">
              <div className="rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4">
                <strong className="text-emerald-200">Importar várias condições</strong>
                <p className="mt-1 text-xs text-slate-400">CSV ou XLSX. O arquivo inteiro é validado antes e a gravação é atômica.</p>
                <form action={importConditions} className="mt-3 space-y-2 text-xs text-slate-400">
                  <input type="hidden" name="version_id" value={v.id}/>
                  <input required type="file" name="file" accept=".csv,.xlsx,text/csv" className="block w-full text-xs"/>
                  <select name="policy_version_id" defaultValue="" className={field+' w-full'}><option value="">Sem regra padrão</option>{policyOpts.map(p=><option key={p.versionId} value={p.versionId}>Regra padrão: {p.name}</option>)}</select>
                  <div className="flex flex-wrap gap-2"><button name="mode" value="preview" className={ghost}>Ver prévia</button><button name="mode" value="apply" className={btn}>Importar planilha</button></div>
                </form>
              </div>
              <details className="rounded-xl border border-slate-800 p-4"><summary className="cursor-pointer font-medium">Adicionar condição manualmente</summary><div className="mt-3"><ConditionForm versionId={v.id} contractTypes={enabledContractTypes} groups={activeGroups} policies={policyOpts}/></div></details>
            </div>}
            {v.status==='draft' && canEdit && conds.map(c => <details key={'edit-'+c.id} className="mt-2"><summary className="cursor-pointer text-xs text-slate-400">Editar {typeN.get(c.contract_type_id) ?? 'condição'} {c.term_min===c.term_max?c.term_min+'x':c.term_min+'–'+c.term_max+'x'}</summary><div className="mt-2"><ConditionForm versionId={v.id} contractTypes={enabledContractTypes} groups={activeGroups} policies={policyOpts} cond={c} received={receivedBy.get(c.id)} shares={sharesBy.get(c.id)} policyVersion={policyOf.get(c.id)}/></div></details>)}
          </div>
        })}
        {canEdit && <form action={newDraftVersion} className="mt-3"><input type="hidden" name="table_id" value={t.id}/><SubmitButton className={ghost}>Nova versão (rascunho)</SubmitButton></form>}
      </div>
    </details>
  }

  return <section>
    <Link href="/app/comercial" className="text-sm text-slate-400 underline">← Voltar ao Comercial</Link>
    <div className="flex flex-wrap items-end justify-between gap-3"><div><h1 className="mt-3 text-3xl font-semibold">Tabelas e condições</h1>
    <p className="mt-2 text-sm text-slate-400">Aqui ficam as tabelas comerciais. Para cada versão rascunho você pode importar uma planilha inteira ou adicionar uma condição manualmente.</p></div><div className="flex flex-wrap gap-2"><Link href="/app/comercial/importacao-inteligente" className="rounded-lg bg-emerald-500 px-3 py-2 text-sm font-semibold text-slate-950">Importação inteligente</Link><a href="/api/comercial/modelo" className="rounded-lg border border-emerald-500/50 px-3 py-2 text-sm text-emerald-300">Baixar modelo XLSX</a></div></div>
    {sp.f === 'ok:previa_validada' && typeof sp.n === 'string' && /^\d{1,5}$/.test(sp.n) && <p className="mt-4 rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4 text-sm text-emerald-200">Prévia validada: {sp.n} condição(ões). Nada foi gravado.</p>}
    {importIssue && <p role="alert" className="mt-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-200">Importação recusada{importLine ? ` — linha ${importLine}` : ''}: {importIssue}</p>}

    {canEdit && (!(banks.data ?? []).some(b=>b.is_active) || !(agreements.data ?? []).some(a=>a.is_active)) && <p className={`${card} mt-5 text-sm text-amber-200`}>Cadastre primeiro uma instituição/origem e um convênio ativo.</p>}
    {canEdit && (banks.data ?? []).some(b=>b.is_active) && (agreements.data ?? []).some(a=>a.is_active) && <form action={createCommercialTable} className={`${card} mt-5 grid gap-2 md:grid-cols-4`}>
      <select required name="bank_id" defaultValue="" className={field}><option value="" disabled>Instituição / origem</option>{(banks.data ?? []).filter(b=>b.is_active).map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select>
      <select required name="agreement_id" defaultValue="" className={field}><option value="" disabled>Convênio</option>{(agreements.data ?? []).filter(a=>a.is_active).map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select>
      <select required name="production_origin" defaultValue="" className={field}><option value="" disabled>Origem da produção</option><option value="own">Própria</option><option value="third_party">Terceiro</option></select>
      <select name="provider_id" defaultValue="" className={field}><option value="">Empresa de origem (se Terceiro)</option>{(providers.data ?? []).filter(p=>p.is_active).map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select>
      <input required name="name" maxLength={120} placeholder="Nome da tabela" className={`${field} md:col-span-2`} />
      <SubmitButton className={`${btn} md:col-span-4 md:justify-self-end`}>Criar tabela</SubmitButton>
    </form>}

    <form method="get" className="mt-5 grid gap-2 rounded-2xl border border-slate-800 bg-slate-900 p-4 md:grid-cols-5">
      <input name="q" defaultValue={typeof sp.q==='string'?sp.q:''} placeholder="Buscar tabela, banco ou promotora" className={field}/>
      <select name="bank" defaultValue={bankFilter} className={field}><option value="">Todos os bancos</option>{bankOptions.map(x=><option key={x} value={x}>{x}</option>)}</select>
      <select name="provider" defaultValue={providerFilter} className={field}><option value="">Todas as origens/promotoras</option>{providerOptions.map(x=><option key={x} value={x}>{x}</option>)}</select>
      <select name="agreement" defaultValue={agreementFilter} className={field}><option value="">Todos os convênios</option>{agreementOptions.map(x=><option key={x} value={x}>{x}</option>)}</select>
      <select name="status" defaultValue={statusFilter} className={field}><option value="current">Somente vigentes</option><option value="all">Todas</option><option value="draft">Com rascunho</option><option value="inactive">Inativas</option></select>
      <div className="flex flex-wrap gap-2 md:col-span-5"><button type="submit" className={btn}>Filtrar</button><Link href="/app/comercial/tabelas" className={ghost}>Limpar filtros</Link><span className="self-center text-xs text-slate-500">{v3Tables.length} tabela(s) encontrada(s)</span></div>
    </form>

    <div className="mt-5 space-y-3">
      {!v3Tables.length && <p className={card+' text-sm text-slate-400'}>Nenhuma tabela encontrada com estes filtros.</p>}
      {[...grouped.entries()].map(([bank,byProvider])=>{
        const bankCount=[...byProvider.values()].reduce((sum,byAgreement)=>sum+[...byAgreement.values()].reduce((n,arr)=>n+arr.length,0),0)
        return <details key={bank} className="rounded-2xl border border-slate-800 bg-slate-900">
          <summary className="cursor-pointer list-none px-5 py-4">
            <div className="flex items-center justify-between gap-3"><div><span className="text-lg font-semibold">{bank}</span><span className="ml-2 text-sm text-slate-500">{bankCount} tabela(s)</span></div><span className="text-xs text-slate-500">Abrir banco</span></div>
          </summary>
          <div className="space-y-3 border-t border-slate-800 p-4">
            {[...byProvider.entries()].map(([provider,byAgreement])=>{
              const providerCount=[...byAgreement.values()].reduce((n,arr)=>n+arr.length,0)
              return <details key={provider} className="rounded-xl border border-slate-800 bg-slate-950/30">
                <summary className="cursor-pointer list-none px-4 py-3">
                  <div className="flex items-center justify-between gap-3"><div><span className="font-medium">{provider}</span><span className="ml-2 text-xs text-slate-500">{providerCount} tabela(s)</span></div><span className="text-xs text-slate-500">Abrir origem</span></div>
                </summary>
                <div className="space-y-3 border-t border-slate-800 p-3">
                  {[...byAgreement.entries()].map(([agreement,items])=><details key={agreement} className="rounded-xl border border-slate-800">
                    <summary className="cursor-pointer list-none px-4 py-3">
                      <div className="flex items-center justify-between gap-3"><div><span className="font-medium">{agreement}</span><span className="ml-2 text-xs text-slate-500">{items.length} tabela(s)</span></div><span className="text-xs text-slate-500">Abrir convênio</span></div>
                    </summary>
                    <div className="space-y-2 border-t border-slate-800 p-3">{items.map(renderTable)}</div>
                  </details>)}
                </div>
              </details>
            })}
          </div>
        </details>
      })}
    </div>
  </section>
}
