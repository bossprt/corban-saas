import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createSeller, createSellerGroup } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'

export default async function SellersPage(){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const [sellerGroups,commissionGroups]=await Promise.all([
    supabase.from('seller_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
  ])

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Vendedores</h1>
    <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
      <p className="max-w-3xl text-sm text-slate-400">Grupo de Vendedor organiza o perfil comercial. Grupo de Comissão define a regra de remuneração. São vínculos diferentes.</p>
      <Link href="/app/cadastros/vendedores/consulta" className="rounded-lg border border-slate-700 px-4 py-2 text-sm font-semibold hover:bg-slate-800">Consultar vendedores cadastrados</Link>
    </div>

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
          <input name="email" type="email" placeholder="E-mail para acesso ao sistema" className={`${field} md:col-span-2`}/>
          <label className="md:col-span-2 flex items-start gap-2 rounded-lg border border-slate-800 bg-slate-950/60 p-3 text-sm">
            <input type="checkbox" name="create_access" defaultChecked className="mt-1"/>
            <span><strong>Criar acesso ao sistema</strong><span className="mt-1 block text-xs text-slate-400">Ligado por padrão. O vendedor entra como Operador e vê somente a própria comissão. Para parceiro externo sem acesso, desmarque.</span></span>
          </label>
        </div>
        <SubmitButton className={`${btn} mt-3`}>Cadastrar vendedor</SubmitButton>
      </form>
    </div>}


    {!canEdit&&<div className={card}><p className="text-sm text-slate-400">Seu perfil pode consultar vendedores cadastrados, mas não criar ou alterar cadastros.</p></div>}
  </section>
}
