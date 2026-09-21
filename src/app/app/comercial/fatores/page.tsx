import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createFactorProfile, createManualFactor, importFactorFile } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'
const MODE:Record<string,string>={daily:'Diário',fixed:'Fixo'}

export default async function FactorsPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
 const canEdit=atLeast(membership.role,'manager')
 const [profiles,banks,agreements,tables,types,batches,entries]=await Promise.all([
  supabase.from('commercial_factor_profiles').select('id,name,org_bank_id,org_agreement_id,product_table_id,contract_type_id,factor_mode,is_active').order('name'),
  supabase.from('organization_banks').select('id,name,is_active').order('name'),
  supabase.from('organization_agreements').select('id,name,is_active').order('name'),
  supabase.from('product_tables').select('id,name,status').order('name'),
  supabase.from('contract_types').select('id,name,is_active').order('sort_order'),
  supabase.from('commercial_factor_batches').select('id,profile_id,effective_date,revision,status,source_kind,source_note,published_at').eq('status','published').order('effective_date',{ascending:false}),
  supabase.from('commercial_factor_entries').select('batch_id,term_min,term_max,factor_value').order('term_min'),
 ])
 const names=(rows:{id:string;name:string}[]|null)=>new Map((rows??[]).map(x=>[x.id,x.name]))
 const bankN=names(banks.data),agrN=names(agreements.data),tableN=names(tables.data),typeN=names(types.data)
 const latest=new Map<string,(typeof batches.data extends (infer T)[]|null?T:never)>()
 for(const b of batches.data??[])if(!latest.has(b.profile_id))latest.set(b.profile_id,b)
 const entriesBy=new Map<string,(typeof entries.data extends (infer T)[]|null?T:never)[]>()
 for(const e of entries.data??[])entriesBy.set(e.batch_id,[...(entriesBy.get(e.batch_id)??[]),e])
 return <section>
  <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
  <h1 className="mt-3 text-3xl font-semibold">Fatores</h1>
  <p className="mt-2 max-w-3xl text-sm text-slate-400">Fatores diários recebem uma vigência por data. Fatores fixos continuam valendo até uma publicação futura. O CRM consulta o fator publicado aplicável.</p>

  {canEdit&&<form action={createFactorProfile} className={`${card} mt-5`}>
   <h2 className="font-semibold">Criar perfil de fator</h2>
   <div className="mt-3 grid gap-2 md:grid-cols-3">
    <input required name="name" maxLength={120} placeholder="Ex.: Daycoval Governo AC Novo" className={field}/>
    <select required name="org_bank_id" defaultValue="" className={field}><option value="" disabled>Instituição</option>{(banks.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select required name="factor_mode" defaultValue="" className={field}><option value="" disabled>Regime</option><option value="daily">Fator diário</option><option value="fixed">Fator fixo</option></select>
    <select name="org_agreement_id" defaultValue="" className={field}><option value="">Todos os convênios</option>{(agreements.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="product_table_id" defaultValue="" className={field}><option value="">Todas as tabelas</option>{(tables.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="contract_type_id" defaultValue="" className={field}><option value="">Todos os tipos de contrato</option>{(types.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
   </div>
   <SubmitButton className={`${btn} mt-3`}>Criar perfil</SubmitButton>
  </form>}

  <div className="mt-5 space-y-3">{!(profiles.data??[]).length?<div className={card}><p className="text-sm text-slate-400">Nenhum perfil de fator cadastrado.</p></div>:(profiles.data??[]).map(p=>{
   const b=latest.get(p.id), es=b?entriesBy.get(b.id)??[]:[]
   return <div key={p.id} className={card}>
    <div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="font-semibold">{p.name}</h2><p className="mt-1 text-xs text-slate-400">{MODE[p.factor_mode]??p.factor_mode} · {bankN.get(p.org_bank_id)??'Instituição'}{p.org_agreement_id?` · ${agrN.get(p.org_agreement_id)??'Convênio'}`:''}{p.product_table_id?` · ${tableN.get(p.product_table_id)??'Tabela'}`:''}{p.contract_type_id?` · ${typeN.get(p.contract_type_id)??'Tipo'}`:''}</p></div>{b&&<span className="text-xs text-emerald-300">Vigente desde {String(b.effective_date)} · rev. {b.revision}</span>}</div>
    {b&&<div className="mt-3 overflow-x-auto"><table className="w-full text-left text-xs"><thead className="text-slate-500"><tr><th className="py-2">Prazo</th><th>Fator</th><th>Origem</th></tr></thead><tbody>{es.map((e,i)=><tr key={i} className="border-t border-slate-800"><td className="py-2">{e.term_min===e.term_max?`${e.term_min}x`:`${e.term_min}–${e.term_max}x`}</td><td>{String(e.factor_value)}</td><td>{b.source_kind}{b.source_note?` · ${b.source_note}`:''}</td></tr>)}</tbody></table></div>}
    {canEdit&&<div className="mt-4 grid gap-3 lg:grid-cols-2">
      <details className="rounded-xl border border-slate-800 p-4"><summary className="cursor-pointer font-medium">Cadastrar manualmente</summary><form action={createManualFactor} className="mt-3 grid gap-2 md:grid-cols-2"><input type="hidden" name="profile_id" value={p.id}/><input required type="date" name="effective_date" className={field}/><input required name="factor_value" inputMode="decimal" placeholder="Fator" className={field}/><input required name="term_min" inputMode="numeric" placeholder="Prazo inicial" className={field}/><input required name="term_max" inputMode="numeric" placeholder="Prazo final" className={field}/><SubmitButton className={ghost}>Publicar fator</SubmitButton></form></details>
      <details className="rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4"><summary className="cursor-pointer font-medium text-emerald-200">Importar fatores</summary><p className="mt-2 text-xs text-slate-400">Nesta primeira entrega: CSV ou XLSX com colunas Prazo Inicial, Prazo Final e Fator. PDF/XLS legado entra na próxima etapa do importador adaptativo.</p><form action={importFactorFile} className="mt-3 space-y-2"><input type="hidden" name="profile_id" value={p.id}/><input required type="date" name="effective_date" className={`${field} w-full`}/><input required type="file" name="file" accept=".csv,.xlsx,text/csv" className="block w-full text-xs"/><SubmitButton className={btn}>Importar e publicar</SubmitButton></form></details>
    </div>}
   </div>
  })}</div>
 </section>
}
