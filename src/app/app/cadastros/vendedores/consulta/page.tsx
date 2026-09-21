import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'
const CAT:Record<string,string>={pf:'PF',pj:'PJ',sub:'SUB'}

export default async function SellersConsultPage({
  searchParams,
}: {
  searchParams?: Promise<{q?:string,status?:string}>
}) {
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const sp=await searchParams
  const q=String(sp?.q??'').trim()
  const status=String(sp?.status??'all')

  const [sellerGroups,commissionGroups]=await Promise.all([
    supabase.from('seller_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
  ])

  let sellersQuery=supabase.from('commercial_sellers')
    .select('id,name,seller_category,tax_id,seller_group_id,commission_group_id,user_id,is_active')
    .order('name')
    .limit(100)

  const safeQ=q.replace(/[%_,]/g,'')
  if(safeQ) sellersQuery=sellersQuery.or('name.ilike.%'+safeQ+'%,tax_id.ilike.%'+safeQ+'%')
  if(status==='active') sellersQuery=sellersQuery.eq('is_active',true)
  if(status==='inactive') sellersQuery=sellersQuery.eq('is_active',false)

  const {data:sellers}=await sellersQuery
  const sg=new Map((sellerGroups.data??[]).map(x=>[x.id,x.name]))
  const cg=new Map((commissionGroups.data??[]).map(x=>[x.id,x.name]))

  return <section>
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div>
        <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
        <h1 className="mt-3 text-3xl font-semibold">Consultar vendedores</h1>
        <p className="mt-2 text-sm text-slate-400">Localize o vendedor, confira o cadastro e altere somente quando necessário.</p>
      </div>
      {canEdit&&<Link href="/app/cadastros/vendedores/novo" className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Cadastrar vendedor</Link>}
    </div>

    <form className={card+' mt-5 grid gap-3 md:grid-cols-[1fr_auto_auto]'}>
      <input name="q" defaultValue={q} placeholder="Buscar por nome ou CPF/CNPJ" className={field}/>
      <select name="status" defaultValue={status} className={field}>
        <option value="all">Todos</option>
        <option value="active">Ativos</option>
        <option value="inactive">Inativos</option>
      </select>
      <button className={ghost}>Buscar</button>
    </form>

    <div className="mt-5 overflow-hidden rounded-2xl border border-slate-800">
      {!(sellers??[]).length
        ? <div className={card}><p className="text-sm text-slate-400">Nenhum vendedor encontrado.</p></div>
        : <div className="divide-y divide-slate-800">{(sellers??[]).map(s=><div key={s.id} className="flex flex-wrap items-center justify-between gap-3 bg-slate-900 p-4">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <h2 className="font-semibold">{s.name}</h2>
                <span className={'text-xs '+(s.is_active?'text-emerald-300':'text-slate-500')}>{s.is_active?'Ativo':'Inativo'}</span>
              </div>
              <p className="mt-1 text-xs text-slate-400">{CAT[s.seller_category]??s.seller_category} · Grupo: {sg.get(s.seller_group_id)??'—'} · Comissão: {cg.get(s.commission_group_id)??'—'}</p>
              {s.tax_id&&<p className="mt-1 text-xs text-slate-500">CPF/CNPJ: {s.tax_id}</p>}
            </div>
            <Link href={'/app/cadastros/vendedores/'+s.id} className="rounded-lg border border-slate-700 px-4 py-2 text-sm font-semibold hover:bg-slate-800">Abrir cadastro</Link>
          </div>)}</div>}
    </div>
  </section>
}
