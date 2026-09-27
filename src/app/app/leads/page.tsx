import { requireAppContext } from '@/lib/appContext'
import { claimLead, convertLead, createLead, setLeadStatus } from './actions'
import { SubmitButton } from '@/components/SubmitButton'
import { digitsOnly, searchTerm } from '@/lib/search'
import { Card, PageHeader, Badge } from '@/components/ui'

const STATUS: Record<string, string> = { new: 'Novo', contacted: 'Contatado', qualified: 'Qualificado', converted: 'Convertido', lost: 'Perdido' }

export default async function LeadsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { supabase } = await requireAppContext()
  const q = searchTerm((await searchParams).q)
  let query = supabase.from('leads').select('id,status,channel,campaign,full_name,phone,created_at,customer_id,owner_user_id').order('created_at', { ascending: false }).limit(100)
  if (q) { const d = digitsOnly(q); query = query.or(d.length >= 4 ? `full_name.ilike.%${q}%,phone.ilike.%${q}%,phone.ilike.%${d}%` : `full_name.ilike.%${q}%`) }
  const { data: leads, error } = await query
  // The leads module needs 20260920_leads_v1 (not applied yet): explicit state, never a silent empty list.
  if (error && ['42P01', 'PGRST205'].includes(String((error as { code?: string }).code))) {
    return <section><PageHeader title="Leads" /><p className="text-sm text-muted">O módulo de leads ainda não está disponível neste ambiente (migration pendente de autorização).</p></section>
  }
  return <section>
    <PageHeader title="Leads" description="Lead → Cliente → Proposta. Leads são CRM: não carregam comissão nem verdade financeira." />
    <Card className="mb-6 p-5">
      <details><summary className="cursor-pointer font-semibold text-ink">Novo lead</summary>
      <form action={createLead} className="mt-4 grid gap-3 md:grid-cols-2">
        <input name="full_name" required minLength={2} placeholder="Nome" className="field" />
        <select name="channel" className="field"><option value="manual">Manual</option><option value="whatsapp">WhatsApp</option><option value="meta_ads">Meta Ads</option><option value="referral">Indicação</option><option value="api">API</option><option value="other">Outro</option></select>
        <input name="phone" placeholder="Telefone" className="field" />
        <input name="email" type="email" placeholder="E-mail" className="field" />
        <input name="campaign" placeholder="Campanha" className="field md:col-span-2" />
        <SubmitButton className="inline-flex h-10 items-center justify-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong md:col-span-2">Registrar lead</SubmitButton>
      </form>
      </details>
    </Card>
    <form className="mb-4 flex gap-2" role="search"><input name="q" defaultValue={q ?? ''} placeholder="Buscar por nome ou telefone" className="field min-w-0 flex-1" /><button className="h-10 rounded-[10px] border border-line bg-surface px-4 text-sm hover:bg-surface-muted">Buscar</button></form>
    {error ? <p role="alert" className="rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-sm text-[#92400E]">Não foi possível consultar os leads agora. Tente de novo.</p> : !leads?.length ? <Card className="p-5"><p className="text-sm text-muted">{q ? 'Nenhum lead encontrado para esta busca.' : 'Nenhum lead ainda. Quando um cliente chamar no WhatsApp, abra "Novo lead" acima e registre nome e telefone; o resto pode ser preenchido depois.'}</p></Card> :
      <div className="space-y-2">{leads.map(l => <Card key={l.id} className="p-4 text-sm">
        <div className="flex flex-wrap items-baseline justify-between gap-2"><strong className="text-ink">{l.full_name}</strong><span className="text-muted">{STATUS[l.status] ?? l.status} · {l.channel}{l.campaign ? ` · ${l.campaign}` : ''}</span></div>
        {l.phone && <div className="mt-1 text-xs text-muted">{l.phone}</div>}
        {!l.owner_user_id && l.status !== 'converted' && l.status !== 'lost' && <form action={claimLead} className="mt-2 flex items-center gap-2"><input type="hidden" name="lead_id" value={l.id} /><Badge tone="diverged">Sem responsável</Badge><button className="rounded-[10px] bg-brand px-2 py-1 text-xs font-semibold text-white hover:bg-brand-strong">Assumir lead</button></form>}
        {l.customer_id && <div className="mt-1 text-xs"><a href={`/app/clientes/${l.customer_id}`} className="text-brand hover:underline">Ver cliente</a></div>}
        {l.status !== 'converted' && <div className="mt-3 flex flex-wrap gap-2">
          {['contacted', 'qualified'].map(s => <form key={s} action={setLeadStatus}><input type="hidden" name="lead_id" value={l.id} /><button name="status" value={s} className="h-8 rounded-[10px] border border-line bg-surface px-2 text-xs hover:bg-surface-muted">Marcar {STATUS[s].toLowerCase()}</button></form>)}
          <form action={setLeadStatus} className="flex gap-1"><input type="hidden" name="lead_id" value={l.id} /><input name="lost_reason" placeholder="Motivo da perda" className="field h-8 px-2 py-1 text-xs" /><button name="status" value="lost" className="h-8 rounded-[10px] border border-line bg-surface px-2 text-xs hover:bg-surface-muted">Perdido</button></form>
          {l.status !== 'lost' && <form action={convertLead} className="flex gap-1"><input type="hidden" name="lead_id" value={l.id} /><input name="cpf" required inputMode="numeric" placeholder="CPF" className="field h-8 px-2 py-1 text-xs" /><button className="h-8 rounded-[10px] bg-brand px-2 text-xs font-semibold text-white hover:bg-brand-strong">Converter em cliente</button></form>}
        </div>}
      </Card>)}</div>}
  </section>
}
