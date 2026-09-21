import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { addSubRule, createSeller, createSellerGroup, setSellerActive, updateSeller } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'
const CAT:Record<string,string>={pf:'PF',pj:'PJ',sub:'SUB'}

export default async function SellersPage(){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const [sellerGroups,commissionGroups,sellers,subRules]=await Promise.all([
    supabase.from('seller_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commercial_sellers').select('id,name,seller_category,tax_id,seller_group_id,commission_group_id,is_active').order('name'),
    supabase.from('seller_sub_rule_versions').select('id,seller_id,component_key,sub_share_pct,company_share_pct,effective_from,status,version').eq('status','published').order('effective_from',{ascending:false}),
  ])
  const sg=new Map((sellerGroups.data??[]).map(x=>[x.id,x.name]))
  const cg=new Map((commissionGroups.data??[]).map(x=>[x.id,x.name]))
  const latestSub=new Map<string,(typeof subRules.data extends (infer T)[]|null?T:never)>()
  for(const r of subRules.data??[])if(!latestSub.has(r.seller_id))latestSub.set(r.seller_id,r)

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Vendedores</h1>
    <p className="mt-2 max-w-3xl text-sm text-slate-400">Grupo de Vendedor organiza o perfil comercial. Grupo de Comissão define a regra de remuneração. São vínculos diferentes.</p>

    {canEdit&&<div className="mt-5 grid gap-4 xl:grid-cols-[1fr_2fr]">
      <form action={createSellerGroup} className={card}>
        <h2 className="font-semibold">Grupo de Vendedor</h2>
        <p className="mt-1 text-xs text-slate-400">Ex.: BÁSICO, Equipe Acre, Parceiros Premium.</p>
        <div className="mt-3 flex gap-2"><input required name="name" maxLength={80} placeholder="Nome do grupo" className={`${field} flex-1`}/><SubmitButton className={btn}>Criar</SubmitButton></div>
      </form>
      <form action={createSeller} className={card}>
        <h2 className="font-semibold">Cadastrar vendedor</h2>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          <input required name="name" maxLength={160} placeholder="Nome / razão social" className={field}/>
          <input name="tax_id" inputMode="numeric" placeholder="CPF/CNPJ (opcional)" className={field}/>
          <select required name="seller_category" defaultValue="" className={field}><option value="" disabled>Categoria</option><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select>
          <select required name="seller_group_id" defaultValue="" className={field}><option value="" disabled>Grupo de Vendedor</option>{(sellerGroups.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
          <select required name="commission_group_id" defaultValue="" className={`${field} md:col-span-2`}><option value="" disabled>Grupo de Comissão</option>{(commissionGroups.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
        </div>
        <SubmitButton className={`${btn} mt-3`}>Cadastrar vendedor</SubmitButton>
      </form>
    </div>}

    <div className="mt-5 space-y-3">{!(sellers.data??[]).length?<div className={card}><p className="text-sm text-slate-400">Nenhum vendedor cadastrado.</p></div>:(sellers.data??[]).map(s=>{
      const sub=latestSub.get(s.id)
      return <div key={s.id} className={card}>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div><h2 className="font-semibold">{s.name}</h2><p className="mt-1 text-xs text-slate-400">{CAT[s.seller_category]??s.seller_category} · Grupo de Vendedor: {sg.get(s.seller_group_id)??'—'} · Grupo de Comissão: {cg.get(s.commission_group_id)??'—'}</p>{s.seller_category==='sub'&&<p className="mt-1 text-xs text-amber-200">{sub?`Regra SUB: ${sub.sub_share_pct}% para SUB / ${sub.company_share_pct}% para empresa · desde ${String(sub.effective_from).slice(0,10)}`:'SUB sem regra econômica publicada.'}</p>}</div>
          <span className={`text-xs ${s.is_active?'text-emerald-300':'text-slate-500'}`}>{s.is_active?'Ativo':'Inativo'}</span>
        </div>
        {canEdit&&<div className="mt-3 flex flex-wrap gap-3">
          <details><summary className="cursor-pointer text-xs underline">Editar cadastro</summary><form action={updateSeller} className="mt-2 grid gap-2 md:grid-cols-2"><input type="hidden" name="id" value={s.id}/><input required name="name" defaultValue={s.name} className={field}/><input name="tax_id" defaultValue={s.tax_id??''} className={field}/><select name="seller_category" defaultValue={s.seller_category} className={field}><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select><select name="seller_group_id" defaultValue={s.seller_group_id} className={field}>{(sellerGroups.data??[]).filter(x=>x.is_active||x.id===s.seller_group_id).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><select name="commission_group_id" defaultValue={s.commission_group_id} className={field}>{(commissionGroups.data??[]).filter(x=>x.is_active||x.id===s.commission_group_id).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>
          {s.seller_category==='sub'&&<details><summary className="cursor-pointer text-xs underline">Nova regra SUB</summary><form action={addSubRule} className="mt-2 flex flex-wrap gap-2"><input type="hidden" name="seller_id" value={s.id}/><input type="hidden" name="component_key" value="all"/><input required name="sub_share_pct" inputMode="decimal" placeholder="% do SUB (ex.: 90)" className={field}/><input required name="effective_from" type="date" className={field}/><SubmitButton className={ghost}>Publicar regra</SubmitButton></form></details>}
          <form action={setSellerActive}><input type="hidden" name="id" value={s.id}/><input type="hidden" name="active" value={s.is_active?'false':'true'}/><SubmitButton className={ghost}>{s.is_active?'Inativar':'Reativar'}</SubmitButton></form>
        </div>}
      </div>
    })}</div>
  </section>
}
