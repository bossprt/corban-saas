import { redirect } from 'next/navigation'
import { Building2, Landmark, Network, Package, Files, Layers3, LogOut } from 'lucide-react'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { signOut } from '@/app/app/actions'
import { addAgreement, addBank, addDocumentType, addModality, addProduct, addProvider, updateBank } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-white'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const button='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-emerald-400'

export default async function PlatformPage({searchParams}:{searchParams:Promise<{ok?:string;erro?:string}>}) {
  const gate=await requirePlatformAdmin()
  if(!gate.ok) redirect('/login')
  const admin=createAdminClient()
  const [banks,providers,products,modalities,agreements,docs,orgs]=await Promise.all([
    admin.from('banks').select('id,code,name,is_active').order('name'),
    admin.from('providers').select('id,code,name,provider_type,is_active').order('name'),
    admin.from('products').select('id,code,name,is_active').order('name'),
    admin.from('modalities').select('id,product_id,code,name,is_active').order('name'),
    admin.from('agreements').select('id,bank_id,code,name,is_active').order('name'),
    admin.from('document_types').select('id,code,name,is_active').order('name'),
    admin.from('organizations').select('id,name,document,is_active').order('name')
  ])
  const sp=await searchParams
  const productNames=new Map((products.data??[]).map(x=>[x.id,x.name]))
  const bankNames=new Map((banks.data??[]).map(x=>[x.id,x.name]))

  return <main className="min-h-screen bg-slate-950 p-4 text-slate-100 md:p-8">
    <div className="mx-auto max-w-7xl">
      <header className="mb-8 flex flex-wrap items-center justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase tracking-[.25em] text-emerald-400">Corban OS Platform</p><h1 className="mt-1 text-3xl font-semibold">Administração da plataforma</h1><p className="mt-2 text-sm text-slate-400">Cadastre a base global que todas as organizações usam para montar suas rotas e tabelas comerciais.</p></div>
        <form action={signOut}><button className="flex items-center gap-2 rounded-lg border border-slate-700 px-4 py-2 text-sm text-slate-300 hover:bg-slate-900"><LogOut size={16}/>Sair</button></form>
      </header>

      {sp.ok&&<p className="mb-5 rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-3 text-sm text-emerald-200">{sp.ok}</p>}
      {sp.erro&&<p className="mb-5 rounded-xl border border-red-500/30 bg-red-500/5 p-3 text-sm text-red-200">{sp.erro}</p>}

      <div className="grid gap-4 md:grid-cols-4">
        <div className={card}><Landmark className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{banks.data?.length??0}</div><div className="text-sm text-slate-400">Instituições</div></div>
        <div className={card}><Building2 className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{orgs.data?.length??0}</div><div className="text-sm text-slate-400">Organizações</div></div>
        <div className={card}><Package className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{products.data?.length??0}</div><div className="text-sm text-slate-400">Produtos</div></div>
        <div className={card}><Network className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{agreements.data?.length??0}</div><div className="text-sm text-slate-400">Convênios</div></div>
      </div>

      <section className="mt-8">
        <h2 className="text-xl font-semibold">Catálogo de referência</h2>
        <p className="mt-1 text-sm text-slate-400">Esta camada não define coeficiente nem comissão. Ela libera os blocos que o Admin de cada empresa usa para criar suas tabelas comerciais.</p>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Landmark size={18}/> Instituições / bancos</h3>
            <form action={addBank} className="mt-4 grid grid-cols-3 gap-2"><input name="code" placeholder="Código (opcional)" className={field}/><input name="name" required placeholder="Nome da instituição" className={field+" col-span-2"}/><button className={button+" col-span-3"}>Cadastrar instituição</button></form>
            <div className="mt-4 space-y-2">{banks.data?.map(x=><form action={updateBank} key={x.id} className="grid grid-cols-1 gap-2 rounded-xl border border-slate-800 p-3 md:grid-cols-[1fr_180px_auto]">
              <input type="hidden" name="id" value={x.id}/>
              <input name="name" required defaultValue={x.name} className={field} aria-label="Nome da instituição"/>
              <input name="code" defaultValue={x.code ?? ''} placeholder="Código opcional" className={field} aria-label="Código da instituição"/>
              <button className="rounded-lg border border-slate-600 px-3 py-2 text-xs font-semibold text-slate-200 hover:bg-slate-800">Salvar edição</button>
            </form>)}</div>
          </div>

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Network size={18}/> Provedores / masters</h3>
            <form action={addProvider} className="mt-4 grid grid-cols-2 gap-2"><input name="code" required placeholder="Código" className={field}/><input name="name" required placeholder="Nome" className={field}/><select name="provider_type" className={field} defaultValue="master"><option value="master">Master</option><option value="bank_direct">Banco direto</option><option value="promotora">Promotora</option><option value="other">Outro</option></select><button className={button}>Cadastrar provedor</button></form>
            <div className="mt-4 flex flex-wrap gap-2">{providers.data?.map(x=><span key={x.id} className="rounded-full border border-slate-700 px-3 py-1 text-xs">{x.name} · {x.provider_type}</span>)}</div>
          </div>

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Package size={18}/> Produtos</h3>
            <form action={addProduct} className="mt-4 grid gap-2"><input name="name" required placeholder="Nome do produto (ex.: Empréstimo Consignado)" className={field}/><button className={button}>Cadastrar produto</button></form>
            <p className="mt-2 text-xs text-slate-500">O identificador técnico é gerado automaticamente pelo sistema e conflitos são resolvidos sem intervenção do usuário.</p>
            <div className="mt-4 flex flex-wrap gap-2">{products.data?.map(x=><span key={x.id} className="rounded-full border border-slate-700 px-3 py-1 text-xs">{x.name}</span>)}</div>
          </div>

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Layers3 size={18}/> Tipos de Contrato</h3>
            <form action={addModality} className="mt-4 grid gap-2"><select name="product_id" required defaultValue="" className={field}><option value="" disabled>Produto</option>{products.data?.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><input name="name" required placeholder="Tipo de contrato (ex.: Novo, Refinanciamento, Portabilidade)" className={field}/><button className={button}>Cadastrar tipo de contrato</button></form>
            <p className="mt-2 text-xs text-slate-500">O identificador técnico é gerado automaticamente.</p>
            <div className="mt-4 space-y-1 text-xs text-slate-300">{modalities.data?.map(x=><div key={x.id}>{productNames.get(x.product_id)??'Produto'} → {x.name}</div>)}</div>
          </div>

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Network size={18}/> Convênios por instituição</h3>
            <form action={addAgreement} className="mt-4 grid gap-2"><select name="bank_id" required defaultValue="" className={field}><option value="" disabled>Instituição / banco</option>{banks.data?.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><input name="name" required placeholder="Convênio (ex.: Governo do Acre)" className={field}/><button className={button}>Cadastrar convênio</button></form>
            <p className="mt-2 text-xs text-slate-500">O identificador técnico é gerado automaticamente dentro da instituição.</p>
            <div className="mt-4 space-y-1 text-xs text-slate-300">{agreements.data?.map(x=><div key={x.id}>{bankNames.get(x.bank_id)??'Instituição'} → {x.name}</div>)}</div>
          </div>

          <div className={card}><h3 className="flex items-center gap-2 font-semibold"><Files size={18}/> Tipos de documento</h3>
            <form action={addDocumentType} className="mt-4 grid gap-2"><input name="name" required placeholder="Tipo de documento (ex.: Contracheque)" className={field}/><button className={button}>Cadastrar documento</button></form>
            <p className="mt-2 text-xs text-slate-500">O identificador técnico é gerado automaticamente.</p>
            <div className="mt-4 flex flex-wrap gap-2">{docs.data?.map(x=><span key={x.id} className="rounded-full border border-slate-700 px-3 py-1 text-xs">{x.name}</span>)}</div>
          </div>
        </div>
      </section>

      <section className="mt-8">
        <h2 className="text-xl font-semibold">Organizações</h2>
        <div className="mt-3 overflow-hidden rounded-2xl border border-slate-800">
          <table className="w-full text-left text-sm"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-3">Empresa</th><th className="p-3">Documento</th><th className="p-3">Status</th></tr></thead><tbody>{orgs.data?.map(o=><tr key={o.id} className="border-t border-slate-800"><td className="p-3">{o.name}</td><td className="p-3 text-slate-400">{o.document}</td><td className="p-3">{o.is_active?'Ativa':'Inativa'}</td></tr>)}</tbody></table>
        </div>
      </section>
    </div>
  </main>
}
