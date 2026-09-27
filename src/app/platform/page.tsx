import { redirect } from 'next/navigation'
import { Building2, Files, LogOut } from 'lucide-react'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { signOut } from '@/app/app/actions'
import { addDocumentType, setOrganizationModule } from './actions'
import { PLAN_MODULE_LABEL, PLAN_MODULES } from '@/lib/access'
import { Card } from '@/components/ui'

const button='inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'

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

  return <main className="min-h-screen bg-canvas p-4 md:p-8">
    <div className="mx-auto max-w-7xl">
      <header className="mb-8 flex flex-wrap items-center justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase tracking-[.25em] text-brand">Corban OS Platform</p><h1 className="mt-1 text-3xl font-semibold text-ink">Administração da plataforma</h1><p className="mt-2 text-sm text-muted">Cadastre a base global que todas as organizações usam para montar suas rotas e tabelas comerciais.</p></div>
        <form action={signOut}><button className="flex h-10 items-center gap-2 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted"><LogOut size={16}/>Sair</button></form>
      </header>

      {sp.ok&&<p role="status" className="mb-5 rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-3 text-sm text-[#15803D]">{sp.ok}</p>}
      {sp.erro&&<p role="alert" className="mb-5 rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">{sp.erro}</p>}

      <div className="grid gap-4 md:grid-cols-2">
        <Card className="p-5"><Building2 className="text-brand"/><div className="mt-3 text-3xl font-semibold text-ink">{orgs.data?.length??0}</div><div className="text-sm text-muted">Organizações</div></Card>
        <Card className="p-5"><Files className="text-brand"/><div className="mt-3 text-3xl font-semibold text-ink">{docs.data?.length??0}</div><div className="text-sm text-muted">Tipos de documento</div></Card>
      </div>

      <section className="mt-8">
        <h2 className="text-xl font-semibold text-ink">Tipos de documento</h2>
        <p className="mt-1 text-sm text-muted">Lista comum a todas as empresas, usada nos documentos do cliente e da proposta. Bancos, convênios e promotoras são cadastrados por cada empresa.</p>
        <div className="mt-4 grid gap-4 lg:grid-cols-2">

          <Card className="p-5"><h3 className="flex items-center gap-2 font-semibold text-ink"><Files size={18}/> Tipos de documento</h3>
            <form action={addDocumentType} className="mt-4 grid gap-2"><input name="name" required placeholder="Tipo de documento (ex.: Contracheque)" className="field"/><button className={button}>Cadastrar documento</button></form>
            <p className="mt-2 text-xs text-muted">O identificador técnico é gerado automaticamente.</p>
            <div className="mt-4 flex flex-wrap gap-2">{docs.data?.map(x=><span key={x.id} className="rounded-full border border-line px-3 py-1 text-xs text-ink-soft">{x.name}</span>)}</div>
          </Card>
        </div>
      </section>

      <section className="mt-8">
        <h2 className="text-xl font-semibold text-ink">Organizações</h2>
        <Card className="mt-3 overflow-hidden">
          <table className="w-full text-left text-sm"><thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="p-3">Empresa</th><th className="p-3">Documento</th><th className="p-3">Status</th></tr></thead><tbody>{orgs.data?.map(o=><tr key={o.id} className="border-t border-line"><td className="p-3 text-ink">{o.name}</td><td className="p-3 text-muted">{o.document}</td><td className="p-3 text-ink-soft">{o.is_active?'Ativa':'Inativa'}</td></tr>)}</tbody></table>
        </Card>
        <h3 className="mt-6 text-lg font-semibold text-ink">Módulos por empresa</h3>
        <p className="mt-1 text-sm text-muted">Liga e desliga módulos de cada empresa conforme o plano. Módulo desligado some do menu e nenhuma permissão dele vale.</p>
        <div className="mt-3 space-y-3">{orgs.data?.map(o=>{const on=new Map((orgModules.data??[]).filter(m=>m.organization_id===o.id).map(m=>[m.module_key,m.enabled]));return <Card key={o.id} className="p-4"><details><summary className="cursor-pointer text-sm font-semibold text-ink">{o.name} <span className="font-normal text-muted">· {PLAN_MODULES.filter(k=>on.get(k)).length} de {PLAN_MODULES.length} módulos ligados</span></summary>
          <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{PLAN_MODULES.map(k=>{const enabled=on.get(k)===true;return <form key={k} action={setOrganizationModule} className="flex items-center justify-between gap-2 rounded-[10px] border border-line px-3 py-2 text-sm"><input type="hidden" name="organization_id" value={o.id}/><input type="hidden" name="module_key" value={k}/><input type="hidden" name="enabled" value={enabled?'false':'true'}/><span className="text-ink-soft">{PLAN_MODULE_LABEL[k]}</span><button className={`rounded-[8px] px-2 py-1 text-xs font-semibold ${enabled?'bg-brand text-white':'border border-line text-muted'}`} aria-label={`${enabled?'Desligar':'Ligar'} ${PLAN_MODULE_LABEL[k]} em ${o.name}`}>{enabled?'Ligado':'Desligado'}</button></form>})}</div>
        </details></Card>})}
        </div>
      </section>
    </div>
  </main>
}
