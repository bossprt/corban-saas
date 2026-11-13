import { redirect } from 'next/navigation'
import { Files, LogOut } from 'lucide-react'
import { requirePlatformAdmin } from '@/lib/platform.server'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { signOut } from '@/app/app/actions'
import { addDocumentType, answerImprovement, createCompanyWithAdmin, publishTermsVersion, setOrganizationModule } from './actions'
import { IMPROVEMENT_KIND, IMPROVEMENT_STATUS } from '@/lib/improvements'
import { PasswordPair } from '@/components/PasswordPair'
import { SubmitButton } from '@/components/SubmitButton'
import { PLAN_MODULE_LABEL, PLAN_MODULES } from '@/lib/access'
import { Badge, Card } from '@/components/ui'
import { brl, CHARGE_STATE, dayLabel, monthLabel } from '@/lib/billing'
import { BillingSection } from './BillingSection'
import { SubscriptionForm } from './SubscriptionForm'

const button='inline-flex h-10 items-center justify-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'

export default async function PlatformPage({searchParams}:{searchParams:Promise<{ok?:string;erro?:string;sol?:string;aba?:string;empresa?:string;nova?:string}>}) {
  const gate=await requirePlatformAdmin()
  if(!gate.ok&&gate.status===401) redirect('/login')
  // Logged in but not a platform administrator: say so instead of looking like the session ended.
  if(!gate.ok) return <main className="flex min-h-screen items-center justify-center bg-canvas p-4">
    <Card className="max-w-md p-6 text-center">
      <h1 className="text-xl font-semibold text-ink">Sem acesso</h1>
      <p className="mt-2 text-sm text-muted">Esta área é só para a administração da plataforma Corban. Sua conta não tem esse acesso.</p>
      <a href="/app" className={`${button} mt-4`}>Voltar ao início</a>
    </Card>
  </main>
  const admin=createAdminClient()
  const [docs,orgs,orgModules,terms,improvements,billingSettings,subscriptions,charges]=await Promise.all([
    admin.from('document_types').select('id,code,name,is_active').order('name'),
    admin.from('organizations').select('id,name,document,is_active').order('name'),
    admin.from('organization_modules').select('organization_id,module_key,enabled'),
    admin.from('terms_versions').select('id,version,published_at').order('published_at',{ascending:false}).limit(1).maybeSingle(),
    admin.from('improvement_requests').select('id,organization_id,protocol,kind,title,body,page_path,status,response,created_at').order('created_at',{ascending:false}).limit(300),
    admin.from('platform_billing_settings').select('pix_key,pix_key_type,merchant_name,merchant_city').maybeSingle(),
    admin.from('organization_subscriptions').select('organization_id,amount::text,due_day,grace_days,starts_on,is_active'),
    admin.rpc('platform_billing_overview'),
  ])
  const today=new Date().toLocaleDateString('sv-SE',{timeZone:'America/Sao_Paulo'})
  // Terms of use (08/10/2026): the version in force and which companies accepted it.
  const currentTerms=terms.data as {id:string;version:string;published_at:string}|null
  const { data: acceptances }=currentTerms?await admin.from('organization_terms_acceptances').select('organization_id,accepted_at').eq('terms_version_id',currentTerms.id):{data:[]}
  const acceptedBy=new Map(((acceptances??[]) as {organization_id:string;accepted_at:string}[]).map(a=>[a.organization_id,a.accepted_at]))
  const sp=await searchParams
  // Improvement requests of every company (08/10/2026): open ones by default; ?sol=todas shows all.
  type Req={id:string;organization_id:string;protocol:string;kind:string;title:string;body:string;page_path:string|null;status:string;response:string|null;created_at:string}
  const allReqs=(improvements.data??[]) as Req[]
  const showAll=sp.sol==='todas'
  const reqs=showAll?allReqs:allReqs.filter(r=>!['declined','delivered'].includes(r.status))
  const orgName=new Map((orgs.data??[]).map(o=>[o.id,o.name]))

  // Tabs (13/11/2026): Empresas (default), Cobrança, Melhorias, Documentos e termos. Same functions as before, one subject per tab.
  const TABS:[string,string][]=[['empresas','Empresas'],['cobranca','Cobrança'],['melhorias','Melhorias'],['documentos','Documentos e termos']]
  const tab=TABS.some(([k])=>k===sp.aba)?sp.aba!:'empresas'
  const openReqs=allReqs.filter(r=>!['declined','delivered'].includes(r.status)).length
  type Sub={organization_id:string;amount:string;due_day:number;grace_days:number;starts_on:string;is_active:boolean}
  type Charge={id:string;organization_id:string;period:string;amount:string;due_on:string;block_on:string;state:string;paid_on:string|null}
  const subs=(subscriptions.data??[]) as Sub[]
  const chargeList=(Array.isArray(charges.data)?charges.data:[]) as Charge[]
  const subOf=new Map(subs.map(x=>[x.organization_id,x]))
  // Latest charge of each company (by period) for the "Mensalidade" column.
  const lastCharge=new Map<string,Charge>()
  for(const c of chargeList){const prev=lastCharge.get(c.organization_id);if(!prev||c.period>prev.period)lastCharge.set(c.organization_id,c)}
  const cnpj=(d:string|null)=>{const x=String(d??'').replace(/\D/g,'');return x.length===14?`${x.slice(0,2)}.${x.slice(2,5)}.${x.slice(5,8)}/${x.slice(8,12)}-${x.slice(12)}`:(d??'')}
  const openOrg=(orgs.data??[]).find(o=>o.id===sp.empresa)
  const openMods=new Map((orgModules.data??[]).filter(m=>m.organization_id===openOrg?.id).map(m=>[m.module_key,m.enabled]))

  return <main className="min-h-screen bg-canvas p-4 md:p-8">
    <div className="mx-auto max-w-7xl">
      <header className="flex flex-wrap items-center justify-between gap-4">
        <div><p className="text-xs font-semibold uppercase tracking-[.25em] text-brand">Corban OS Platform</p><h1 className="mt-1 text-3xl font-semibold text-ink">Administração da plataforma</h1></div>
        <form action={signOut}><button className="flex h-10 items-center gap-2 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted"><LogOut size={16}/>Sair</button></form>
      </header>

      <nav aria-label="Seções da plataforma" className="mb-6 mt-6 flex gap-1 overflow-x-auto border-b border-line">
        {TABS.map(([k,l])=><a key={k} href={`/platform?aba=${k}`} aria-current={tab===k?'page':undefined} className={`-mb-px flex shrink-0 items-center gap-1.5 border-b-[3px] px-4 py-2.5 text-sm ${tab===k?'border-brand font-semibold text-brand':'border-transparent text-muted hover:text-ink'}`}>{l}{k==='melhorias'&&<span className={`rounded-full px-1.5 text-[11px] font-semibold ${openReqs?'bg-[#FDE2E1] text-[#B42318]':'bg-surface-muted text-muted'}`}>{openReqs}</span>}</a>)}
      </nav>

      {sp.ok&&<p role="status" className="mb-5 rounded-[10px] border border-[#BBE5C8] bg-[#E3F5E9] px-4 py-3 text-sm text-[#15803D]">{sp.ok}</p>}
      {sp.erro&&<p role="alert" className="mb-5 rounded-[10px] border border-[#F5C2C0] bg-[#FDE2E1] px-4 py-3 text-sm text-[#991B1B]">{sp.erro}</p>}

      {tab==='empresas'&&<>
        <Card className="overflow-hidden">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-5 py-4">
            <h2 className="font-semibold text-ink">Empresas ({orgs.data?.length??0})</h2>
            <a href="/platform?aba=empresas&nova=1#nova-empresa" className={button}>+ Nova empresa</a>
          </div>
          <div className="relative overflow-x-auto"><table className="w-full min-w-[640px] text-left text-sm"><thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-5 py-2.5">Empresa</th><th className="px-5 py-2.5">CNPJ</th><th className="px-5 py-2.5">Situação</th><th className="px-5 py-2.5">Mensalidade</th><th className="px-5 py-2.5">Módulos</th><th className="px-5 py-2.5"><span className="sr-only">Ações</span></th></tr></thead>
          <tbody>{orgs.data?.map(o=>{const s=subOf.get(o.id);const c=lastCharge.get(o.id);const mods=(orgModules.data??[]).filter(m=>m.organization_id===o.id&&m.enabled&&(PLAN_MODULES as readonly string[]).includes(m.module_key)).length;const cl=c?(CHARGE_STATE[c.state]?.[0]??c.state):'';const isOpen=openOrg?.id===o.id;return <tr key={o.id} className={`border-t border-line ${isOpen?'bg-[#EEF3FB]':''}`}>
            <td className="px-5 py-3.5 font-semibold text-ink">{o.name}</td>
            <td className="num px-5 py-3.5 text-ink-soft">{cnpj(o.document)}</td>
            <td className="px-5 py-3.5"><Badge tone={o.is_active?'received':'neutral'}>{o.is_active?'Ativa':'Inativa'}</Badge></td>
            <td className="px-5 py-3.5">{s&&s.is_active?<><span className="num text-ink">{brl(s.amount)} · dia {s.due_day}</span>{c&&<div className="text-xs text-muted">{monthLabel(c.period)} · {c.paid_on?`paga em ${dayLabel(c.paid_on).slice(0,5)}`:cl}</div>}</>:<Badge tone="neutral">{s?'Cobrança desligada':'Sem cobrança'}</Badge>}</td>
            <td className="num px-5 py-3.5 text-ink-soft">{mods} de {PLAN_MODULES.length}</td>
            <td className="px-5 py-3.5 text-right"><a href={isOpen?'/platform?aba=empresas':`/platform?aba=empresas&empresa=${o.id}#empresa`} className="font-semibold text-brand hover:underline">{isOpen?'Fechar':'Abrir'}</a></td>
          </tr>})}</tbody></table></div>
        </Card>

        {openOrg&&<Card id="empresa" className="mt-5 p-5">
          <div className="flex flex-wrap items-center justify-between gap-2"><h2 className="font-semibold text-ink">{openOrg.name}</h2><a href="/platform?aba=empresas" className="text-sm text-muted hover:text-ink">Fechar</a></div>
          <h3 className="mt-4 text-sm font-semibold text-ink">Mensalidade</h3>
          <div className="mt-2 rounded-[10px] border border-line p-4"><SubscriptionForm orgId={openOrg.id} orgName={openOrg.name} sub={subOf.get(openOrg.id)} today={today} fromCompany /></div>
          <h3 className="mt-5 text-sm font-semibold text-ink">Módulos</h3>
          <p className="mt-1 text-xs text-muted">Módulo desligado some do menu da empresa e nenhuma permissão dele vale.</p>
          <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{PLAN_MODULES.map(k=>{const enabled=openMods.get(k)===true;return <form key={k} action={setOrganizationModule} className="flex items-center justify-between gap-2 rounded-[10px] border border-line px-3 py-2 text-sm"><input type="hidden" name="organization_id" value={openOrg.id}/><input type="hidden" name="module_key" value={k}/><input type="hidden" name="enabled" value={enabled?'false':'true'}/><input type="hidden" name="aba" value="empresas"/><input type="hidden" name="empresa" value={openOrg.id}/><span className="text-ink-soft">{PLAN_MODULE_LABEL[k]}</span><button className={`rounded-[8px] px-2 py-1 text-xs font-semibold ${enabled?'bg-brand text-white':'border border-line text-muted'}`} aria-label={`${enabled?'Desligar':'Ligar'} ${PLAN_MODULE_LABEL[k]} em ${openOrg.name}`}>{enabled?'Ligado':'Desligado'}</button></form>})}</div>
        </Card>}

        {sp.nova==='1'&&<Card id="nova-empresa" className="mt-5 p-5">
          <h2 className="font-semibold text-ink">Nova empresa</h2>
          <p className="mt-1 text-sm text-muted">Cria a empresa e o login do primeiro administrador. Ele mesmo cria a equipe, os vendedores e os cadastros da empresa.</p>
          <form action={createCompanyWithAdmin} className="mt-4 grid gap-3 sm:grid-cols-2">
            <input type="hidden" name="aba" value="empresas"/>
            <label className="text-xs text-muted">Nome da empresa<input name="organization_name" required minLength={3} maxLength={200} className="field mt-1 block" /></label>
            <label className="text-xs text-muted">CNPJ<input name="organization_document" required inputMode="numeric" placeholder="00.000.000/0000-00" className="field mt-1 block" /></label>
            <label className="text-xs text-muted">Nome do administrador<input name="full_name" required minLength={3} maxLength={160} className="field mt-1 block" /></label>
            <label className="text-xs text-muted">E-mail do administrador (login)<input name="email" type="email" required maxLength={254} autoComplete="off" className="field mt-1 block" /></label>
            <div className="flex flex-wrap items-end gap-3 sm:col-span-2"><PasswordPair idPrefix="nova-empresa" label="Senha do administrador" /></div>
            <label className="flex items-center gap-1.5 text-xs text-muted sm:col-span-2"><input type="checkbox" name="must_change" defaultChecked className="accent-[var(--brand)]" />Pedir nova senha no primeiro acesso</label>
            <label className="flex items-center gap-1.5 text-xs text-muted sm:col-span-2"><input type="checkbox" name="confirm_similar" className="accent-[var(--brand)]" />Se avisar de nome parecido: o nome parecido está certo</label>
            <div className="flex flex-wrap gap-2 sm:col-span-2"><SubmitButton pendingText="Criando..." className={button}>Criar empresa e administrador</SubmitButton><a href="/platform?aba=empresas" className="inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-4 text-sm text-ink hover:bg-surface-muted">Cancelar</a></div>
          </form>
        </Card>}
      </>}

      {tab==='cobranca'&&<BillingSection settings={billingSettings.data} today={today} orgs={(orgs.data??[]).map(o=>({id:o.id,name:o.name}))} subs={subs} charges={chargeList}/>}

      {tab==='melhorias'&&<section>
        <div className="flex flex-wrap items-end justify-between gap-2">
          <p className="text-sm text-muted">Pedidos das empresas pelo botão Sugerir melhoria. A resposta aparece para quem pediu e para o administrador da empresa.</p>
          <a href={showAll?'/platform?aba=melhorias':'/platform?aba=melhorias&sol=todas'} className="text-sm text-brand hover:underline">{showAll?'Só as abertas':`Ver todas (${allReqs.length})`}</a>
        </div>
        <div className="mt-3 space-y-3">{reqs.map(r=>{const [st,tone]=IMPROVEMENT_STATUS[r.status]??[r.status,'neutral' as const];return <Card key={r.id} className="p-4">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm"><span className="font-mono text-xs text-muted">{r.protocol}</span><span className="font-medium text-ink">{r.title}</span><Badge tone="neutral">{IMPROVEMENT_KIND[r.kind]??r.kind}</Badge><Badge tone={tone}>{st}</Badge><span className="ml-auto text-xs text-muted">{orgName.get(r.organization_id)??'Empresa'} · {new Date(r.created_at).toLocaleString('pt-BR',{timeZone:'America/Sao_Paulo'})}{r.page_path?` · ${r.page_path}`:''}</span></div>
          <p className="mt-1 whitespace-pre-wrap text-sm text-ink-soft">{r.body}</p>
          <form action={answerImprovement} className="mt-3 grid gap-2 sm:grid-cols-[220px_1fr_auto] sm:items-end"><input type="hidden" name="request_id" value={r.id}/><input type="hidden" name="aba" value="melhorias"/>
            <label className="text-xs text-muted">Situação<select name="status" defaultValue={r.status} className="field mt-1 block">{Object.entries(IMPROVEMENT_STATUS).map(([k,[v]])=><option key={k} value={k}>{v}</option>)}</select></label>
            <label className="text-xs text-muted">Resposta para a empresa<input name="response" maxLength={4000} defaultValue={r.response??''} placeholder="Obrigatória para Não será feita" className="field mt-1 block"/></label>
            <SubmitButton pendingText="Salvando..." className={button}>Salvar</SubmitButton>
          </form>
        </Card>})}
        {!reqs.length&&<Card className="p-4"><p className="text-sm text-muted">Nenhuma solicitação {showAll?'':'aberta'}.</p></Card>}
        </div>
      </section>}

      {tab==='documentos'&&<>
        <section>
          <h2 className="text-xl font-semibold text-ink">Tipos de documento ({docs.data?.length??0})</h2>
          <p className="mt-1 text-sm text-muted">Lista comum a todas as empresas, usada nos documentos do cliente e da proposta. Bancos, convênios e promotoras são cadastrados por cada empresa.</p>
          <Card className="mt-3 p-5">
            <form action={addDocumentType} className="grid gap-2 sm:grid-cols-[1fr_auto]"><input type="hidden" name="aba" value="documentos"/><input name="name" required placeholder="Tipo de documento (ex.: Contracheque)" className="field"/><button className={button}><Files size={16} className="mr-1.5"/>Cadastrar documento</button></form>
            <p className="mt-2 text-xs text-muted">O identificador técnico é gerado automaticamente.</p>
            <div className="mt-4 flex flex-wrap gap-2">{docs.data?.map(x=><span key={x.id} className="rounded-full border border-line px-3 py-1 text-xs text-ink-soft">{x.name}</span>)}</div>
          </Card>
        </section>
      <section className="mt-8">
        <h2 className="text-xl font-semibold text-ink">Termos de uso</h2>
        <p className="mt-1 text-sm text-muted">{currentTerms ? `Em vigor: versão ${currentTerms.version}, publicada em ${new Date(currentTerms.published_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}.` : 'Nenhuma versão publicada: ninguém precisa aceitar termos ainda.'}</p>
        {currentTerms && <Card className="mt-3 overflow-hidden"><table className="w-full text-left text-sm"><thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="p-3">Empresa</th><th className="p-3">Aceite da versão em vigor</th></tr></thead><tbody>{orgs.data?.map(o => { const a = acceptedBy.get(o.id); return <tr key={o.id} className="border-t border-line"><td className="p-3 text-ink">{o.name}</td><td className="p-3 text-ink-soft">{a ? `Aceito em ${new Date(a).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}` : 'Aguardando o administrador'}</td></tr> })}</tbody></table></Card>}
        <Card className="mt-3 p-5">
          <details>
            <summary className="cursor-pointer text-sm font-semibold text-ink">Publicar nova versão</summary>
            <form action={publishTermsVersion} className="mt-3 grid gap-3">
              <input type="hidden" name="aba" value="documentos" />
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

      </>}
    </div>
  </main>
}
