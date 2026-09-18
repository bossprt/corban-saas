import { requireAppContext } from '@/lib/appContext'
export default async function CatalogPage() {
  const { supabase } = await requireAppContext()
  const [banks, providers, routes, tables] = await Promise.all([
    supabase.from('banks').select('id,code,name,is_active').order('name'),
    supabase.from('providers').select('id,code,name,provider_type,is_active').order('name'),
    supabase.from('organization_product_routes').select('id,status,external_code').order('created_at',{ascending:false}),
    supabase.from('product_tables').select('id,code,name,status').order('name'),
  ])
  return <section><h1 className="text-3xl font-semibold">Catálogo</h1><p className="mt-2 text-sm text-slate-400">Bancos, masters, rotas habilitadas e tabelas do tenant.</p>
    <div className="mt-6 grid gap-4 md:grid-cols-4">{[
      ['Bancos',banks.data?.length??0],['Providers / Masters',providers.data?.length??0],['Rotas do tenant',routes.data?.length??0],['Tabelas',tables.data?.length??0]
    ].map(([l,v])=><div key={String(l)} className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{l}</div><div className="mt-2 text-3xl font-semibold">{v}</div></div>)}</div>
    <div className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-medium">Bancos disponíveis</h2><div className="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{banks.data?.map(b=><div key={b.id} className="rounded-lg bg-slate-950 p-3 text-sm"><span className="text-slate-500">{b.code}</span> · {b.name}</div>)}{!banks.data?.length&&<p className="text-sm text-slate-500">Catálogo global ainda sem dados publicados.</p>}</div></div>
  </section>
}