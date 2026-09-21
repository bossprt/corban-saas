import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createCommercialTable } from '../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function TablesPage({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const {supabase,membership}=await requireAppContext()
  const sp=await searchParams
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')

  const [banks,providers,agreements,routes,tables,versionsQ]=await Promise.all([
    supabase.from('organization_banks').select('id,name,is_active').order('name'),
    supabase.from('organization_providers').select('id,name,is_active').order('name'),
    supabase.from('organization_agreements').select('id,name,is_active').order('name'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status').not('org_bank_id','is',null),
    supabase.from('product_tables').select('id,route_id,name,status').order('name'),
    supabase.from('product_table_versions').select('id,product_table_id,version,status,effective_from,effective_until').order('version',{ascending:false}),
  ])

  const nameOf=(rows:{id:string;name:string}[]|null)=>new Map((rows??[]).map(r=>[r.id,r.name]))
  const bankN=nameOf(banks.data),provN=nameOf(providers.data),agrN=nameOf(agreements.data)
  const routeMeta=new Map((routes.data??[]).map(r=>[
    r.id,
    {
      bank:bankN.get(r.org_bank_id)??'Instituição',
      agreement:agrN.get(r.org_agreement_id)??'Convênio',
      provider:r.production_origin==='third_party'?(provN.get(r.org_provider_id)??'Terceiro'):'Próprio / Smart',
    }
  ]))
  const allTables=(tables.data??[]).filter(t=>routeMeta.has(t.route_id))
  const versions=versionsQ.data??[]
  const now=new Date()

  const currentVersion=(tableId:string)=>versions.find(v=>{
    if(v.product_table_id!==tableId||v.status!=='published')return false
    const from=v.effective_from?new Date(v.effective_from):new Date(0)
    const until=v.effective_until?new Date(v.effective_until):null
    return from<=now&&(!until||now<until)
  })
  const hasDraft=(tableId:string)=>versions.some(v=>v.product_table_id===tableId&&v.status==='draft')

  const q=typeof sp.q==='string'?sp.q.trim().toLocaleLowerCase('pt-BR'):''
  const bankFilter=typeof sp.bank==='string'?sp.bank:''
  const providerFilter=typeof sp.provider==='string'?sp.provider:''
  const agreementFilter=typeof sp.agreement==='string'?sp.agreement:''
  const statusFilter=typeof sp.status==='string'?sp.status:'current'

  const filtered=allTables.filter(t=>{
    const m=routeMeta.get(t.route_id)!
    if(bankFilter&&m.bank!==bankFilter)return false
    if(providerFilter&&m.provider!==providerFilter)return false
    if(agreementFilter&&m.agreement!==agreementFilter)return false
    if(statusFilter==='current'&&!currentVersion(t.id))return false
    if(statusFilter==='draft'&&!hasDraft(t.id))return false
    if(statusFilter==='inactive'&&t.status==='active')return false
    if(q&&!([t.name,m.bank,m.provider,m.agreement].join(' ').toLocaleLowerCase('pt-BR').includes(q)))return false
    return true
  })

  const grouped=new Map<string,Map<string,Map<string,typeof filtered>>>()
  for(const t of filtered){
    const m=routeMeta.get(t.route_id)!
    if(!grouped.has(m.bank))grouped.set(m.bank,new Map())
    const byProvider=grouped.get(m.bank)!
    if(!byProvider.has(m.provider))byProvider.set(m.provider,new Map())
    const byAgreement=byProvider.get(m.provider)!
    if(!byAgreement.has(m.agreement))byAgreement.set(m.agreement,[])
    byAgreement.get(m.agreement)!.push(t)
  }

  const bankOptions=[...new Set(allTables.map(t=>routeMeta.get(t.route_id)!.bank))].sort((a,b)=>a.localeCompare(b,'pt-BR'))
  const providerOptions=[...new Set(allTables.map(t=>routeMeta.get(t.route_id)!.provider))].sort((a,b)=>a.localeCompare(b,'pt-BR'))
  const agreementOptions=[...new Set(allTables.map(t=>routeMeta.get(t.route_id)!.agreement))].sort((a,b)=>a.localeCompare(b,'pt-BR'))

  return <section>
    <Link href="/app/comercial" className="text-sm text-slate-400 underline">← Voltar ao Comercial</Link>
    <div className="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="mt-3 text-3xl font-semibold">Tabelas e condições</h1>
        <p className="mt-2 text-sm text-slate-400">Catálogo comercial por Banco → Origem/Promotora → Convênio. As condições são carregadas somente quando você abre uma tabela.</p>
      </div>
      <div className="flex flex-wrap gap-2">
        <Link href="/app/comercial/importacao-inteligente" className={btn}>Importação inteligente</Link>
        <a href="/api/comercial/modelo" className="rounded-lg border border-emerald-500/50 px-3 py-2 text-sm text-emerald-300">Baixar modelo XLSX</a>
      </div>
    </div>

    {canEdit&&(banks.data??[]).some(b=>b.is_active)&&(agreements.data??[]).some(a=>a.is_active)&&<details className={card+' mt-5'}>
      <summary className="cursor-pointer font-medium">Cadastrar tabela manualmente</summary>
      <form action={createCommercialTable} className="mt-4 grid gap-2 md:grid-cols-4">
        <select required name="bank_id" defaultValue="" className={field}><option value="" disabled>Instituição / origem</option>{(banks.data??[]).filter(b=>b.is_active).map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <select required name="agreement_id" defaultValue="" className={field}><option value="" disabled>Convênio</option>{(agreements.data??[]).filter(a=>a.is_active).map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select>
        <select required name="production_origin" defaultValue="" className={field}><option value="" disabled>Origem da produção</option><option value="own">Própria</option><option value="third_party">Terceiro</option></select>
        <select name="provider_id" defaultValue="" className={field}><option value="">Empresa de origem (se Terceiro)</option>{(providers.data??[]).filter(p=>p.is_active).map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select>
        <input required name="name" maxLength={120} placeholder="Nome da tabela" className={field+' md:col-span-2'}/>
        <SubmitButton className={btn+' md:col-span-4 md:justify-self-end'}>Criar tabela</SubmitButton>
      </form>
    </details>}

    <form method="get" className="mt-5 grid gap-2 rounded-2xl border border-slate-800 bg-slate-900 p-4 md:grid-cols-5">
      <input name="q" defaultValue={typeof sp.q==='string'?sp.q:''} placeholder="Buscar tabela, banco ou promotora" className={field}/>
      <select name="bank" defaultValue={bankFilter} className={field}><option value="">Todos os bancos</option>{bankOptions.map(x=><option key={x}>{x}</option>)}</select>
      <select name="provider" defaultValue={providerFilter} className={field}><option value="">Todas as origens/promotoras</option>{providerOptions.map(x=><option key={x}>{x}</option>)}</select>
      <select name="agreement" defaultValue={agreementFilter} className={field}><option value="">Todos os convênios</option>{agreementOptions.map(x=><option key={x}>{x}</option>)}</select>
      <select name="status" defaultValue={statusFilter} className={field}><option value="current">Somente vigentes</option><option value="all">Todas</option><option value="draft">Com rascunho</option><option value="inactive">Inativas</option></select>
      <div className="flex flex-wrap gap-2 md:col-span-5"><button className={btn}>Filtrar</button><Link href="/app/comercial/tabelas" className={ghost}>Limpar filtros</Link><span className="self-center text-xs text-slate-500">{filtered.length} tabela(s)</span></div>
    </form>

    <div className="mt-5 space-y-3">
      {!filtered.length&&<p className={card+' text-sm text-slate-400'}>Nenhuma tabela encontrada.</p>}
      {[...grouped.entries()].map(([bank,byProvider])=>{
        const count=[...byProvider.values()].reduce((a,b)=>a+[...b.values()].reduce((x,y)=>x+y.length,0),0)
        return <details key={bank} className="rounded-2xl border border-slate-800 bg-slate-900">
          <summary className="cursor-pointer list-none px-5 py-4"><span className="text-lg font-semibold">{bank}</span><span className="ml-2 text-sm text-slate-500">{count} tabela(s)</span></summary>
          <div className="space-y-3 border-t border-slate-800 p-4">
            {[...byProvider.entries()].map(([provider,byAgreement])=><details key={provider} className="rounded-xl border border-slate-800 bg-slate-950/30">
              <summary className="cursor-pointer list-none px-4 py-3"><span className="font-medium">{provider}</span><span className="ml-2 text-xs text-slate-500">{[...byAgreement.values()].reduce((n,a)=>n+a.length,0)} tabela(s)</span></summary>
              <div className="space-y-3 border-t border-slate-800 p-3">
                {[...byAgreement.entries()].map(([agreement,items])=><details key={agreement} className="rounded-xl border border-slate-800">
                  <summary className="cursor-pointer list-none px-4 py-3"><span className="font-medium">{agreement}</span><span className="ml-2 text-xs text-slate-500">{items.length} tabela(s)</span></summary>
                  <div className="divide-y divide-slate-800 border-t border-slate-800">
                    {items.map(t=>{
                      const v=currentVersion(t.id)
                      return <div key={t.id} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                        <div><div className="font-medium">{t.name}</div><div className="text-xs text-slate-500">{v?'v'+v.version+' vigente':'Sem versão vigente'}{hasDraft(t.id)?' · possui rascunho':''}</div></div>
                        <Link href={'/app/comercial/tabelas/'+t.id} className="rounded-lg border border-emerald-500/50 px-3 py-2 text-sm text-emerald-300">Abrir tabela</Link>
                      </div>
                    })}
                  </div>
                </details>)}
              </div>
            </details>)}
          </div>
        </details>
      })}
    </div>
  </section>
}
