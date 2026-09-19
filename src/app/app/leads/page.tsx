import { requireAppContext } from '@/lib/appContext'
import { convertLead, createLead, setLeadStatus } from './actions'

const STATUS: Record<string, string> = { new: 'Novo', contacted: 'Contatado', qualified: 'Qualificado', converted: 'Convertido', lost: 'Perdido' }

export default async function LeadsPage() {
  const { supabase } = await requireAppContext()
  const { data: leads, error } = await supabase.from('leads').select('id,status,channel,campaign,full_name,phone,created_at,customer_id').order('created_at', { ascending: false }).limit(100)
  // The leads module needs 20260920_leads_v1 (not applied yet): explicit state, never a silent empty list.
  if (error && ['42P01', 'PGRST205'].includes(String((error as { code?: string }).code))) {
    return <section><h1 className="text-3xl font-semibold">Leads</h1><p className="mt-3 text-sm text-slate-400">O módulo de leads ainda não está disponível neste ambiente (migration pendente de autorização).</p></section>
  }
  return <section>
    <h1 className="text-3xl font-semibold">Leads</h1>
    <p className="mt-2 text-sm text-slate-400">Lead → Cliente → Proposta. Leads são CRM: não carregam comissão nem verdade financeira.</p>
    <details className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5"><summary className="cursor-pointer font-semibold">Novo lead</summary>
      <form action={createLead} className="mt-4 grid gap-3 md:grid-cols-2">
        <input name="full_name" required minLength={2} placeholder="Nome" className="rounded-lg border border-slate-700 bg-slate-950 p-2" />
        <select name="channel" className="rounded-lg border border-slate-700 bg-slate-950 p-2"><option value="manual">Manual</option><option value="whatsapp">WhatsApp</option><option value="meta_ads">Meta Ads</option><option value="referral">Indicação</option><option value="api">API</option><option value="other">Outro</option></select>
        <input name="phone" placeholder="Telefone" className="rounded-lg border border-slate-700 bg-slate-950 p-2" />
        <input name="email" type="email" placeholder="E-mail" className="rounded-lg border border-slate-700 bg-slate-950 p-2" />
        <input name="campaign" placeholder="Campanha" className="rounded-lg border border-slate-700 bg-slate-950 p-2 md:col-span-2" />
        <button className="rounded-lg bg-emerald-500 px-4 py-2 font-semibold text-slate-950 md:col-span-2">Registrar lead</button>
      </form></details>
    {error ? <p role="alert" className="mt-4 text-amber-300">Não foi possível consultar os leads.</p> : !leads?.length ? <p className="mt-4 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhum lead.</p> :
      <div className="mt-4 space-y-2">{leads.map(l => <div key={l.id} className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm">
        <div className="flex flex-wrap items-baseline justify-between gap-2"><strong>{l.full_name}</strong><span className="text-slate-400">{STATUS[l.status] ?? l.status} · {l.channel}{l.campaign ? ` · ${l.campaign}` : ''}</span></div>
        {l.status !== 'converted' && <div className="mt-3 flex flex-wrap gap-2">
          {['contacted', 'qualified'].map(s => <form key={s} action={setLeadStatus}><input type="hidden" name="lead_id" value={l.id} /><button name="status" value={s} className="rounded border border-slate-700 px-2 py-1 text-xs">Marcar {STATUS[s].toLowerCase()}</button></form>)}
          <form action={setLeadStatus} className="flex gap-1"><input type="hidden" name="lead_id" value={l.id} /><input name="lost_reason" placeholder="Motivo da perda" className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs" /><button name="status" value="lost" className="rounded border border-slate-700 px-2 py-1 text-xs">Perdido</button></form>
          {l.status !== 'lost' && <form action={convertLead} className="flex gap-1"><input type="hidden" name="lead_id" value={l.id} /><input name="cpf" required inputMode="numeric" placeholder="CPF" className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs" /><button className="rounded bg-emerald-500 px-2 py-1 text-xs font-semibold text-slate-950">Converter em cliente</button></form>}
        </div>}
      </div>)}</div>}
  </section>
}
