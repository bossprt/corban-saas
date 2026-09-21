import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { saveComponentPolicy } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const MODE_LABEL:Record<string,string>={share_of_received:'% do componente recebido',direct:'Valor direto',exclude:'Não repassar'}

export default async function CommissionRulesPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
 const canEdit=atLeast(membership.role,'manager')
 const [groups,components,banks,agreements,tables,policies,versions,items]=await Promise.all([
  supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
  supabase.from('commission_component_types').select('id,tech_key,name,sort_order,is_active').eq('is_active',true).order('sort_order'),
  supabase.from('organization_banks').select('id,name,is_active').eq('is_active',true).order('name'),
  supabase.from('organization_agreements').select('id,name,is_active').eq('is_active',true).order('name'),
  supabase.from('product_tables').select('id,name,status').eq('status','active').order('name'),
  supabase.from('component_payout_policies').select('id,name,org_bank_id,org_agreement_id,product_table_id,is_active').eq('is_active',true).order('name'),
  supabase.from('component_payout_policy_versions').select('id,policy_id,version,discount_pct,effective_from').order('version',{ascending:false}),
  supabase.from('component_payout_policy_items').select('version_id,group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value')
 ])
 const names=(r:{id:string;name:string}[])=>new Map(r.map(x=>[x.id,x.name]))
 const bn=names(banks.data??[]),an=names(agreements.data??[]),tn=names(tables.data??[]),gn=names(groups.data??[]),cn=names(components.data??[])
 return <section>
  <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
  <h1 className="mt-3 text-3xl font-semibold">Regras de comissão por componente</h1>
  <p className="mt-2 max-w-4xl text-sm text-slate-400">Defina uma vez como cada Grupo de Comissão recebe À Vista, Diferido, Bônus, Plástico e Seguro. A regra pode valer para toda a empresa ou ser específica por instituição, convênio ou tabela.</p>

  {canEdit&&<form action={saveComponentPolicy} className={`${card} mt-5 space-y-5`}>
   <div className="grid gap-2 md:grid-cols-3">
    <input required name="name" maxLength={100} placeholder="Nome da regra (ex.: Governo AC padrão)" className={field}/>
    <input required type="date" name="effective_from" className={field}/>
    <input name="discount" inputMode="decimal" defaultValue="0" placeholder="Imposto/desconto % (ex.: 6)" className={field}/>
    <select name="bank_id" defaultValue="" className={field}><option value="">Todas as instituições</option>{(banks.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="agreement_id" defaultValue="" className={field}><option value="">Todos os convênios</option>{(agreements.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="table_id" defaultValue="" className={field}><option value="">Todas as tabelas</option>{(tables.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
   </div>
   <div className="overflow-x-auto"><table className="min-w-[1100px] w-full text-xs"><thead><tr><th className="p-2 text-left">Grupo</th>{(components.data??[]).map(c=><th key={c.id} className="p-2 text-left">{c.name}</th>)}</tr></thead><tbody>{(groups.data??[]).map(g=><tr key={g.id} className="border-t border-slate-800"><td className="p-2 font-medium">{g.name}</td>{(components.data??[]).map(c=>{const k=`${g.id}_${c.id}`;return <td key={c.id} className="p-2"><select name={`m_${k}`} defaultValue="exclude" className={`${field} w-full`}><option value="exclude">Não repassar</option><option value="share_of_received">% do recebido</option><option value="direct">Valor direto</option></select><input name={`v_${k}`} inputMode="decimal" placeholder="Valor" className={`${field} mt-1 w-full`}/><select name={`k_${k}`} defaultValue="percentage" className={`${field} mt-1 w-full`}><option value="percentage">%</option><option value="fixed_brl">R$</option></select></td>})}</tr>)}</tbody></table></div>
   <p className="text-xs text-slate-500">Quando usar “% do recebido”, informe por exemplo 65 para Corretores e 80 para Parceiros. Se o componente não deve ser repassado, deixe “Não repassar”.</p>
   <SubmitButton className={btn}>Salvar regra versionada</SubmitButton>
  </form>}

  <div className="mt-5 space-y-3">{(policies.data??[]).map(p=>{
   const v=(versions.data??[]).find(x=>x.policy_id===p.id)
   const vi=(items.data??[]).filter(x=>x.version_id===v?.id)
   return <div key={p.id} className={card}><div className="flex flex-wrap justify-between gap-3"><div><h2 className="font-semibold">{p.name}</h2><p className="mt-1 text-xs text-slate-400">{p.org_bank_id?bn.get(p.org_bank_id):'Toda empresa'}{p.org_agreement_id?` · ${an.get(p.org_agreement_id)}`:''}{p.product_table_id?` · ${tn.get(p.product_table_id)}`:''}</p></div>{v&&<span className="text-xs text-emerald-300">v{v.version} · imposto/desconto {String(v.discount_pct)}%</span>}</div>{v&&<div className="mt-3 grid gap-2 md:grid-cols-2 xl:grid-cols-3">{vi.filter(x=>x.mode!=='exclude').map((x,i)=><div key={i} className="rounded-lg border border-slate-800 p-2 text-xs">{gn.get(x.group_id)} · {cn.get(x.component_type_id)}: {MODE_LABEL[x.mode]} {x.mode==='share_of_received'?`${x.share_pct}%`:x.mode==='direct'?`${x.direct_value_kind==='fixed_brl'?'R$':'%'} ${x.direct_value}`:''}</div>)}</div>}</div>
  })}</div>
 </section>
}
