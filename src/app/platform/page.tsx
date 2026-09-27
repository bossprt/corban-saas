import { redirect } from 'next/navigation'
import { Building2, Files, LogOut } from 'lucide-react'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { signOut } from '@/app/app/actions'
import { addDocumentType, setOrganizationModule } from './actions'
import { PLAN_MODULE_LABEL, PLAN_MODULES } from '@/lib/access'

const field='rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-white'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const button='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-emerald-400'

export default async function PlatformPage({searchParams}:{searchParams:Promise<{ok?:string;erro?:string}>}) {
  const gate=await requirePlatformAdmin()
  if(!gate.ok) redirect('/login')
  const admin=createAdminClient()
  const [docs,orgs,orgModules]=await Promise.all([
    admin.from('document_types').select('id,code,name,is_active').order('name'),
    admin.from('organizations').select('id,name,document,is_active').order('name'),
    admin.from('organization_modules').select('organization_id,module_key,enabled')
  ])
  const sp=await searchParams

  return <main className="min-h-screen bg-slate-950 p-4 text-slate-100 md:p-8">
    <div className="mx-auto max-w-7xl">
      <header className="mb-8 flex flex-wrap items-center justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase tracking-[.25em] text-emerald-400">Corban OS Platform</p><h1 className="mt-1 text-3xl font-semibold">Administração da plataforma</h1><p className="mt-2 text-sm text-slate-400">Cadastre a base global que todas as organizações usam para montar suas rotas e tabelas comerciais.</p></div>
        <form action={signOut}><button className="flex items-center gap-2 rounded-lg border border-slate-700 px-4 py-2 text-sm text-slate-300 hover:bg-slate-900"><LogOut size={16}/>Sair</button></form>
      </header>

      {sp.ok&&<p className="mb-5 rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-3 text-sm text-emerald-200">{sp.ok}</p>}
      {sp.erro&&<p className="mb-5 rounded-xl border border-red-500/30 bg-red-500/5 p-3 text-sm text-red-200">{sp.erro}</p>}

      <div className="grid gap-4 md:grid-cols-2">
        <div className={card}><Building2 className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{orgs.data?.length??0}</div><div className="text-sm text-slate-400">Organizações</div></div>
        <div className={card}><Files className="text-emerald-400"/><div className="mt-3 text-3xl font-semibold">{docs.data?.length??0}</div><div className="text-sm text-slate-400">Tipos de documento</div></div>
      </div>

      <section className="mt-8">
        <h2 className="text-xl font-semibold">Tipos de documento</h2>
        <p className="mt-1 text-sm text-slate-400">Lista comum a todas as empresas, usada nos documentos do cliente e da proposta. Bancos, convênios e promotoras são cadastrados por cada empresa.</p>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">

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
        <h3 className="mt-6 text-lg font-semibold">Módulos por empresa</h3>
        <p className="mt-1 text-sm text-slate-400">Liga e desliga módulos de cada empresa conforme o plano. Módulo desligado some do menu e nenhuma permissão dele vale.</p>
        <div className="mt-3 space-y-3">{orgs.data?.map(o=>{const on=new Map((orgModules.data??[]).filter(m=>m.organization_id===o.id).map(m=>[m.module_key,m.enabled]));return <details key={o.id} className="rounded-xl border border-slate-800 bg-slate-900 p-4"><summary className="cursor-pointer text-sm font-semibold">{o.name} <span className="font-normal text-slate-400">· {PLAN_MODULES.filter(k=>on.get(k)).length} de {PLAN_MODULES.length} módulos ligados</span></summary>
          <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{PLAN_MODULES.map(k=>{const enabled=on.get(k)===true;return <form key={k} action={setOrganizationModule} className="flex items-center justify-between gap-2 rounded-lg border border-slate-800 px-3 py-2 text-sm"><input type="hidden" name="organization_id" value={o.id}/><input type="hidden" name="module_key" value={k}/><input type="hidden" name="enabled" value={enabled?'false':'true'}/><span>{PLAN_MODULE_LABEL[k]}</span><button className={`rounded px-2 py-1 text-xs font-semibold ${enabled?'bg-emerald-500 text-slate-950':'border border-slate-700 text-slate-400'}`} aria-label={`${enabled?'Desligar':'Ligar'} ${PLAN_MODULE_LABEL[k]} em ${o.name}`}>{enabled?'Ligado':'Desligado'}</button></form>})}</div>
        </details>})}
        </div>
      </section>
    </div>
  </main>
}
