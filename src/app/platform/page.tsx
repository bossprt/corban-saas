import { redirect } from 'next/navigation'
import { Building2, Files, LogOut } from 'lucide-react'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { signOut } from '@/app/app/actions'
import { addDocumentType, createCompanyWithAdmin, publishTermsVersion, setOrganizationModule } from './actions'
import { PasswordPair } from '@/components/PasswordPair'
import { SubmitButton } from '@/components/SubmitButton'
import { PLAN_MODULE_LABEL, PLAN_MODULES } from '@/lib/access'
import { Card } from '@/components/ui'

const button='inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'

export default async function PlatformPage({searchParams}:{searchParams:Promise<{ok?:string;erro?:string}>}) {
  const gate=await requirePlatformAdmin()
  if(!gate.ok) redirect('/login')
  const admin=createAdminClient()
  const [docs,orgs,orgModules,terms]=await Promise.all([
    admin.from('document_types').select('id,code,name,is_active').order('name'),
    admin.from('organizations').select('id,name,document,is_active').order('name'),
    admin.from('organization_modules').select('organization_id,module_key,enabled'),
    admin.from('terms_versions').select('id,version,published_at').order('published_at',{ascending:false}).limit(1).maybeSingle(),
  ])
  // Terms of use (08/10/2026): the version in force and which companies accepted it.
  const currentTerms=terms.data as {id:string;version:string;published_at:string}|null
  const { data: acceptances }=currentTerms?await admin.from('organization_terms_acceptances').select('organization_id,accepted_at').eq('terms_version_id',currentTerms.id):{data:[]}
  const acceptedBy=new Map(((acceptances??[]) as {organization_id:string;accepted_at:string}[]).map(a=>[a.organization_id,a.accepted_at]))
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
        <h2 className="text-xl font-semibold text-ink">Termos de uso</h2>
        <p className="mt-1 text-sm text-muted">{currentTerms ? `Em vigor: versão ${currentTerms.version}, publicada em ${new Date(currentTerms.published_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}.` : 'Nenhuma versão publicada: ninguém precisa aceitar termos ainda.'}</p>
        {currentTerms && <Card className="mt-3 overflow-hidden"><table className="w-full text-left text-sm"><thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="p-3">Empresa</th><th className="p-3">Aceite da versão em vigor</th></tr></thead><tbody>{orgs.data?.map(o => { const a = acceptedBy.get(o.id); return <tr key={o.id} className="border-t border-line"><td className="p-3 text-ink">{o.name}</td><td className="p-3 text-ink-soft">{a ? `Aceito em ${new Date(a).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}` : 'Aguardando o administrador'}</td></tr> })}</tbody></table></Card>}
        <Card className="mt-3 p-5">
          <details>
            <summary className="cursor-pointer text-sm font-semibold text-ink">Publicar nova versão</summary>
            <form action={publishTermsVersion} className="mt-3 grid gap-3">
              <div className="grid gap-3 sm:grid-cols-2">
                <label className="text-xs text-muted">Versão<input name="version" required maxLength={40} placeholder="2026-10" className="field mt-1 block" /></label>
                <label className="text-xs text-muted">Título<input name="title" required maxLength={200} defaultValue="Termos de Uso e Política de Privacidade do Corban" className="field mt-1 block" /></label>
              </div>
              <label className="text-xs text-muted">Texto completo (o aprovado pelo advogado)<textarea name="body" required rows={12} className="field mt-1 block w-full font-mono text-xs" /></label>
              <label className="flex items-start gap-1.5 text-xs text-muted"><input type="checkbox" name="confirm" className="mt-0.5 accent-[var(--brand)]" />O texto foi aprovado. Ao publicar, todas as empresas terão de aceitar esta versão no próximo acesso do administrador, e o texto não poderá ser alterado (uma correção é uma nova versão).</label>
              <div><SubmitButton pendingText="Publicando..." className={button}>Publicar termos</SubmitButton></div>
            </form>
          </details>
        </Card>
      </section>

      <section className="mt-8">
        <h2 className="text-xl font-semibold text-ink">Nova empresa</h2>
        <p className="mt-1 text-sm text-muted">Cria a empresa e o login do primeiro administrador. Ele mesmo cria a equipe, os vendedores e os cadastros da empresa.</p>
        <Card className="mt-3 p-5">
          <form action={createCompanyWithAdmin} className="grid gap-3 sm:grid-cols-2">
            <label className="text-xs text-muted">Nome da empresa<input name="organization_name" required minLength={3} maxLength={200} className="field mt-1 block" /></label>
            <label className="text-xs text-muted">CNPJ<input name="organization_document" required inputMode="numeric" placeholder="00.000.000/0000-00" className="field mt-1 block" /></label>
            <label className="text-xs text-muted">Nome do administrador<input name="full_name" required minLength={3} maxLength={160} className="field mt-1 block" /></label>
            <label className="text-xs text-muted">E-mail do administrador (login)<input name="email" type="email" required maxLength={254} autoComplete="off" className="field mt-1 block" /></label>
            <div className="flex flex-wrap items-end gap-3 sm:col-span-2"><PasswordPair idPrefix="nova-empresa" label="Senha do administrador" /></div>
            <label className="flex items-center gap-1.5 text-xs text-muted sm:col-span-2"><input type="checkbox" name="must_change" defaultChecked className="accent-[var(--brand)]" />Pedir nova senha no primeiro acesso</label>
            <label className="flex items-center gap-1.5 text-xs text-muted sm:col-span-2"><input type="checkbox" name="confirm_similar" className="accent-[var(--brand)]" />Se avisar de nome parecido: o nome parecido está certo</label>
            <div className="sm:col-span-2"><SubmitButton pendingText="Criando..." className={button}>Criar empresa e administrador</SubmitButton></div>
          </form>
        </Card>
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
