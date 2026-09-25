import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createContractType, saveContractTypeSettings, updateOwnContractType } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function ContractTypesPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
 const canEdit=atLeast(membership.role,'manager')
 const [types,settings]=await Promise.all([
  supabase.from('contract_types').select('id,name,tech_key,is_active,sort_order,organization_id').order('sort_order').order('name'),
  supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission')
 ])
 const setting=new Map((settings.data??[]).map(x=>[x.contract_type_id,x]))
 return <section>
  <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Cadastros</Link>
  <h1 className="mt-3 text-3xl font-semibold">Tipos de Contrato</h1>
  <p className="mt-2 max-w-3xl text-sm text-slate-400">Tipos globais como Novo, Refinanciamento, Portabilidade e Refin/Portabilidade podem ser habilitados conforme a operação. Sua empresa também pode criar tipos próprios.</p>

  {canEdit&&<form action={createContractType} className={`${card} mt-5 flex flex-wrap gap-2`}>
   <input required name="name" maxLength={80} placeholder="Novo tipo de contrato" className={`${field} min-w-64 flex-1`}/>
   <SubmitButton className={btn}>Cadastrar tipo</SubmitButton>
  </form>}

  <div className="mt-5 space-y-3">{(types.data??[]).map(t=>{
   const s=setting.get(t.id)
   const global=t.organization_id===null
   return <div key={t.id} className={card}>
    <div className="flex flex-wrap items-start justify-between gap-3">
     <div><h2 className="font-semibold">{t.name}</h2><p className="mt-1 text-xs text-slate-500">{global?'Padrão da plataforma':'Criado pela sua empresa'} · {t.is_active?'Ativo':'Inativo'}</p></div>
     {t.tech_key==='refin_portabilidade'&&<span className="rounded-full border border-emerald-500/30 px-3 py-1 text-xs text-emerald-300">Refinanciamento da Portabilidade</span>}
    </div>
    <form action={saveContractTypeSettings} className="mt-4 flex flex-wrap items-center gap-5 text-sm">
     <input type="hidden" name="contract_type_id" value={t.id}/>
     <label><input type="checkbox" name="is_enabled" defaultChecked={s?.is_enabled??true} className="mr-2"/>Habilitado</label>
     <label><input type="checkbox" name="use_in_pipeline" defaultChecked={s?.use_in_pipeline??true} className="mr-2"/>Usar na esteira</label>
     <label><input type="checkbox" name="use_in_commission" defaultChecked={s?.use_in_commission??true} className="mr-2"/>Usar em comissão</label>
     {canEdit&&<SubmitButton className={ghost}>Salvar configuração</SubmitButton>}
    </form>
    {!global&&canEdit&&<details className="mt-3"><summary className="cursor-pointer text-xs underline">Editar tipo próprio</summary><form action={updateOwnContractType} className="mt-2 flex flex-wrap gap-2"><input type="hidden" name="id" value={t.id}/><input name="name" required defaultValue={t.name} className={field}/><select name="active" defaultValue={t.is_active?'true':'false'} className={field}><option value="true">Ativo</option><option value="false">Inativo</option></select><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>}
   </div>
  })}</div>
 </section>
}
