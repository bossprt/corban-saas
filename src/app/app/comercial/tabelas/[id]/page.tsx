import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { effectiveContractTypes } from '@/lib/contract-types'
import { importConditions, newDraftVersion, publishCommercialVersion, saveCondition } from '../../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'
const VSTATUS:Record<string,string>={draft:'Rascunho',published:'Publicada',superseded:'Substituída',expired:'Expirada'}
const show=(v:number|string|null|undefined)=>(v===null||v===undefined?'—':String(v))
const showPct=(v:number|string|null|undefined)=>{
  if(v===null||v===undefined||v==='')return '—'
  const n=Number(v)
  return Number.isFinite(n)?n.toFixed(2):'—'
}

type Group={id:string;name:string;calculation_basis:string}
type PolicyOpt={versionId:string;name:string}
type Condition={id:string;contract_type_id:string;term:number;term_min:number;term_max:number;coefficient:number|null;rate:number|null}

function ConditionForm({versionId,contractTypes,groups,policies,cond,received,shares,policyVersion}:{
  versionId:string
  contractTypes:{id:string;name:string}[]
  groups:Group[]
  policies:PolicyOpt[]
  cond?:Condition
  received?:number|null
  shares?:Map<string,number>
  policyVersion?:string|null
}){
  return <form action={saveCondition} className="grid gap-2 md:grid-cols-4">
    <input type="hidden" name="version_id" value={versionId}/>
    {cond&&<input type="hidden" name="condition_id" value={cond.id}/>}
    <select required name="contract_type_id" defaultValue={cond?.contract_type_id??''} className={field}>
      <option value="" disabled>Tipo de Contrato</option>
      {contractTypes.map(t=><option key={t.id} value={t.id}>{t.name}</option>)}
    </select>
    <input required name="term_min" inputMode="numeric" defaultValue={cond?.term_min??cond?.term??''} placeholder="Prazo inicial" className={field}/>
    <input required name="term_max" inputMode="numeric" defaultValue={cond?.term_max??cond?.term??''} placeholder="Prazo final" className={field}/>
    <input name="coefficient" inputMode="decimal" defaultValue={cond?.coefficient??''} placeholder="Coeficiente" className={field}/>
    <input name="rate" inputMode="decimal" defaultValue={cond?.rate??''} placeholder="Taxa (%)" className={field}/>
    <input required name="received" inputMode="decimal" defaultValue={received??''} placeholder="Comissão empresa (%)" className={field}/>
    <select name="policy_version_id" defaultValue={policyVersion??''} className={field}>
      <option value="">Sem regra padrão</option>
      {policies.map(p=><option key={p.versionId} value={p.versionId}>{p.name}</option>)}
    </select>
    {groups.map(g=><label key={g.id} className="text-xs text-slate-400">
      {g.name}
      <input name={'g_'+g.id} inputMode="decimal" defaultValue={shares?.get(g.id)??''} placeholder="% (vazio = regra padrão)" className={field+' mt-1 w-full'}/>
    </label>)}
    <SubmitButton className={ghost+' md:col-span-4 md:justify-self-end'} pendingText="Salvando...">{cond?'Salvar alterações':'Adicionar condição'}</SubmitButton>
  </form>
}

export default async function CommercialTableDetail({
  params,searchParams
}:{
  params:Promise<{id:string}>
  searchParams:Promise<Record<string,string|string[]|undefined>>
}){
  const {id}=await params
  const sp=await searchParams
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const seeCommission=canViewCommission(membership.role)
  const showHistory=sp.history==='1'

  const tableQ=await supabase.from('product_tables').select('id,route_id,name,status').eq('id',id).maybeSingle()
  if(!tableQ.data)notFound()
  const table=tableQ.data

  const [routeQ,banksQ,providersQ,agreementsQ,versionsQ,groupsQ,contractTypesQ,settingsQ,polRowsQ,polVersionsQ]=await Promise.all([
    supabase.from('organization_product_routes').select('id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status').eq('id',table.route_id).maybeSingle(),
    supabase.from('organization_banks').select('id,name'),
    supabase.from('organization_providers').select('id,name'),
    supabase.from('organization_agreements').select('id,name'),
    supabase.from('product_table_versions').select('id,product_table_id,version,status,effective_from,effective_until,metadata').eq('product_table_id',id).order('version',{ascending:false}),
    supabase.from('commission_groups').select('id,name,calculation_basis,is_active').order('sort_order').order('name'),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('payout_policies').select('id,name,is_active').order('name'),
    supabase.from('payout_policy_versions').select('id,policy_id,version').order('version',{ascending:false}),
  ])
  if(!routeQ.data)notFound()

  const bankName=(banksQ.data??[]).find(x=>x.id===routeQ.data?.org_bank_id)?.name??'Instituição'
  const agreementName=(agreementsQ.data??[]).find(x=>x.id===routeQ.data?.org_agreement_id)?.name??'Convênio'
  const providerName=routeQ.data.production_origin==='third_party'
    ?((providersQ.data??[]).find(x=>x.id===routeQ.data?.org_provider_id)?.name??'Terceiro')
    :'Próprio / Smart'

  const now=new Date()
  const versions=(versionsQ.data??[])
  const visibleVersions=showHistory
    ? versions
    : versions.filter(v=>{
        if(v.status==='draft')return true
        if(v.status!=='published')return false
        const from=v.effective_from?new Date(v.effective_from):new Date(0)
        const until=v.effective_until?new Date(v.effective_until):null
        return from<=now&&(!until||now<until)
      })
  const versionIds=visibleVersions.map(v=>v.id)

  const conditionsQ=versionIds.length
    ?await supabase.from('commercial_conditions')
       .select('id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate')
       .in('product_table_version_id',versionIds)
       .order('term_min')
    :{data:[],error:null}
  if(conditionsQ.error)throw conditionsQ.error
  const conditions=(conditionsQ.data??[]) as (Condition&{product_table_version_id:string})[]
  const conditionIds=conditions.map(c=>c.id)

  const [commissionsQ,componentsQ,sharesQ]=conditionIds.length&&seeCommission
    ?await Promise.all([
        supabase.from('commercial_condition_commissions').select('condition_id,received_commission_pct,policy_version_id').in('condition_id',conditionIds),
        supabase.from('commercial_condition_components').select('condition_id,calculation_base').in('condition_id',conditionIds),
        supabase.from('commercial_condition_shares').select('condition_id,group_id,share_pct,effective_pct,source').in('condition_id',conditionIds),
      ])
    :[{data:[]},{data:[]},{data:[]}]

  const enabledTypes=effectiveContractTypes(
    (contractTypesQ.data??[]) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[],
    (settingsQ.data??[]) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[],
    'commission'
  )
  const typeN=new Map(enabledTypes.map(t=>[t.id,t.name]))
  const activeGroups=(groupsQ.data??[]).filter(g=>g.is_active) as Group[]
  const receivedBy=new Map((commissionsQ.data??[]).map(c=>[c.condition_id,c.received_commission_pct]))
  const policyOf=new Map((commissionsQ.data??[]).map(c=>[c.condition_id,c.policy_version_id]))
  const baseBy=new Map<string,string>()
  for(const x of componentsQ.data??[])if(x.calculation_base&&!baseBy.has(x.condition_id))baseBy.set(x.condition_id,x.calculation_base)
  const effectiveBy=new Map<string,Map<string,number>>()
  const manualSharesBy=new Map<string,Map<string,number>>()
  for(const s of sharesQ.data??[]){
    if(!effectiveBy.has(s.condition_id))effectiveBy.set(s.condition_id,new Map())
    effectiveBy.get(s.condition_id)!.set(s.group_id,s.effective_pct)
    if(s.source!=='policy'){
      if(!manualSharesBy.has(s.condition_id))manualSharesBy.set(s.condition_id,new Map())
      manualSharesBy.get(s.condition_id)!.set(s.group_id,s.share_pct)
    }
  }
  const policies:PolicyOpt[]=(polRowsQ.data??[]).filter(p=>p.is_active).map(p=>{
    const v=(polVersionsQ.data??[]).find(x=>x.policy_id===p.id)
    return v?{versionId:v.id,name:p.name}:null
  }).filter((x):x is PolicyOpt=>Boolean(x))

  return <section>
    <Link href="/app/comercial/tabelas" className="text-sm text-slate-400 underline">← Voltar às tabelas</Link>
    <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h1 className="text-2xl font-semibold">{table.name}</h1>
        <p className="mt-1 text-sm text-slate-400">{bankName} · {providerName} · {agreementName}</p>
      </div>
      <Link href={showHistory?'/app/comercial/tabelas/'+id:'/app/comercial/tabelas/'+id+'?history=1'} className={ghost}>
        {showHistory?'Ocultar histórico':'Ver histórico'}
      </Link>
    </div>

    <div className="mt-5 space-y-4">
      {visibleVersions.map(v=>{
        const conds=conditions.filter(c=>c.product_table_version_id===v.id)
        return <div key={v.id} className={card}>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <span className="font-medium">v{v.version} · {VSTATUS[v.status]??v.status}</span>
              <span className="ml-2 text-xs text-slate-500">{conds.length} condição(ões)</span>
              {v.effective_from&&<span className="ml-2 text-xs text-slate-500">início {new Date(v.effective_from).toLocaleDateString('pt-BR',{timeZone:'UTC'})}</span>}
              {v.effective_until&&<span className="ml-2 text-xs text-slate-500">fim {new Date(v.effective_until).toLocaleDateString('pt-BR',{timeZone:'UTC'})}</span>}
            </div>
            {v.status==='draft'&&canEdit&&<form action={publishCommercialVersion}><input type="hidden" name="version_id" value={v.id}/><SubmitButton className={btn} pendingText="Publicando...">Publicar</SubmitButton></form>}
          </div>

          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[1250px] text-left text-xs">
              <thead className="text-slate-500"><tr>
                <th className="py-2 pr-4">Tipo</th>
                <th className="pr-4">Prazo inicial</th>
                <th className="pr-4">Prazo final</th>
                <th className="pr-4">Coef.</th>
                <th className="pr-4">Taxa</th>
                {seeCommission&&<>
                  <th className="pr-4">Comissão empresa</th>
                  <th className="pr-4">Base</th>
                  {activeGroups.map(g=><th key={g.id} className="pr-4 whitespace-nowrap">{g.name}</th>)}
                </>}
              </tr></thead>
              <tbody>
                {conds.map(c=><tr key={c.id} className="border-t border-slate-800">
                  <td className="py-2 pr-4 whitespace-nowrap">{typeN.get(c.contract_type_id)??'Tipo'}</td>
                  <td className="pr-4">{c.term_min}</td>
                  <td className="pr-4">{c.term_max}</td>
                  <td className="pr-4">{show(c.coefficient)}</td>
                  <td className="pr-4">{showPct(c.rate)}%</td>
                  {seeCommission&&<>
                    <td className="pr-4 font-medium">{showPct(receivedBy.get(c.id))}%</td>
                    <td className="pr-4">{baseBy.get(c.id)??'—'}</td>
                    {activeGroups.map(g=>{
                      const effective=effectiveBy.get(c.id)?.get(g.id)
                      return <td key={g.id} className="pr-4">{effective===undefined?'—':showPct(effective)+'%'}</td>
                    })}
                  </>}
                </tr>)}
              </tbody>
            </table>
          </div>

          {v.status==='draft'&&canEdit&&<div className="mt-5 grid gap-4 lg:grid-cols-2">
            <div className="rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4">
              <strong className="text-emerald-200">Importar condições</strong>
              <p className="mt-1 text-xs text-slate-400">Use Prazo Inicial e Prazo Final. Se for um prazo único, repita o mesmo valor nas duas colunas.</p>
              <form action={importConditions} className="mt-3 space-y-2">
                <input type="hidden" name="version_id" value={v.id}/>
                <input required type="file" name="file" accept=".csv,.xlsx,text/csv" className="block w-full text-xs"/>
                <select name="policy_version_id" defaultValue="" className={field+' w-full'}><option value="">Sem regra padrão</option>{policies.map(p=><option key={p.versionId} value={p.versionId}>{p.name}</option>)}</select>
                <div className="flex gap-2"><button name="mode" value="preview" className={ghost}>Ver prévia</button><button name="mode" value="apply" className={btn}>Importar</button></div>
              </form>
            </div>
            <details className="rounded-xl border border-slate-800 p-4">
              <summary className="cursor-pointer font-medium">Adicionar condição manualmente</summary>
              <div className="mt-3"><ConditionForm versionId={v.id} contractTypes={enabledTypes} groups={activeGroups} policies={policies}/></div>
            </details>
          </div>}

          {v.status==='draft'&&canEdit&&conds.map(c=><details key={'edit-'+c.id} className="mt-2">
            <summary className="cursor-pointer text-xs text-slate-400">Editar {typeN.get(c.contract_type_id)??'condição'} {c.term_min===c.term_max?c.term_min+'x':c.term_min+'–'+c.term_max+'x'}</summary>
            <div className="mt-2"><ConditionForm versionId={v.id} contractTypes={enabledTypes} groups={activeGroups} policies={policies} cond={c} received={receivedBy.get(c.id)} shares={manualSharesBy.get(c.id)} policyVersion={policyOf.get(c.id)}/></div>
          </details>)}
        </div>
      })}
    </div>

    {canEdit&&<form action={newDraftVersion} className="mt-4"><input type="hidden" name="table_id" value={id}/><SubmitButton className={ghost}>Nova versão (rascunho)</SubmitButton></form>}
  </section>
}
