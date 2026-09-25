import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { isSeverity, SEVERITY_LABEL, SEVERITY_ORDER, type Severity } from '@/lib/attention-rules'
import { loadAttention, type AttentionRow } from '@/lib/attention.server'
import { decideAttention } from './actions'

const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-xs'
const TONE: Record<Severity, string> = { critical: 'border-red-500/50 text-red-300', high: 'border-amber-500/50 text-amber-300', medium: 'border-sky-500/40 text-sky-300', low: 'border-slate-700 text-slate-300' }
const EVENT: Record<string, string> = { detected: 'Detectado', severity_changed: 'Gravidade mudou', resolved: 'Resolvido', auto_resolved: 'Resolvido sozinho (a condição acabou)', dismissed: 'Ignorado', snoozed: 'Adiado', reopened: 'Reaberto', assigned: 'Atribuído' }
const STATUS: Record<string, string> = { open: 'Aberto', snoozed: 'Adiado', dismissed: 'Ignorado', resolved: 'Resolvido' }

type Row = AttentionRow

export default async function AttentionPage() {
  const ctx = await requireAppContext()
  const { membership } = ctx
  if (!atLeast(membership.role, 'supervisor')) return <section><h1 className="text-3xl font-semibold">Central de atenção</h1>
    <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">A central de atenção é restrita a supervisor, gerente e administrador.</p></section>

  const { persistent, items: shown, events, notEvaluated } = await loadAttention(ctx, { withEvents: true })

  return <section>
    <h1 className="text-3xl font-semibold">Central de atenção</h1>
    <p className="mt-2 text-sm text-slate-400">Sinais calculados por regras objetivas (prazos, filas, falhas). Nenhum alerta muda dados da operação: ele só mostra onde agir. Ignorar exige motivo e tudo fica no histórico.</p>
    {!persistent && <p className="mt-3 rounded-xl border border-slate-800 p-3 text-xs text-slate-400">Histórico e decisões ainda não estão habilitados neste ambiente. Os sinais abaixo são calculados agora.</p>}
    {notEvaluated.length > 0 && <p className="mt-3 rounded-xl border border-amber-500/30 p-3 text-xs text-amber-200">Não foi possível conferir agora: {notEvaluated.join(', ')}. Isso não significa &ldquo;zero&rdquo;.</p>}
    {!shown.length && <p className={`${card} mt-6 text-sm text-emerald-300`}>Nada pendente agora.</p>}
    {SEVERITY_ORDER.map(sev => {
      const list = shown.filter(i => (isSeverity(i.severity) ? i.severity : 'low') === sev)
      if (!list.length) return null
      return <div key={sev} className="mt-6"><h2 className={`text-sm font-semibold uppercase tracking-wide ${TONE[sev].split(' ')[1]}`}>{SEVERITY_LABEL[sev]} ({list.length})</h2>
        <div className="mt-2 space-y-3">{list.map(i => <article key={i.id} className={`${card} border ${TONE[sev].split(' ')[0]}`}>
          <div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-medium">{i.title}</h3><p className="mt-1 text-sm text-slate-400">{i.reason}</p></div>
            <span className="rounded-full border border-slate-700 px-2 py-0.5 text-xs text-slate-300">{STATUS[i.status] ?? i.status}{i.status === 'snoozed' && i.snoozed_until ? ` até ${new Date(i.snoozed_until).toLocaleDateString('pt-BR')}` : ''}</span></div>
          <dl className="mt-3 grid gap-2 text-xs text-slate-400 md:grid-cols-3">
            <div><dt className="text-slate-500">Evidência</dt><dd>{i.evidence?.count ?? '—'} item(ns){i.evidence?.oldest_at ? `; o mais antigo desde ${new Date(i.evidence.oldest_at).toLocaleString('pt-BR')}` : ''}</dd></div>
            <div><dt className="text-slate-500">Impacto</dt><dd>{i.impact}</dd></div>
            <div><dt className="text-slate-500">Próxima ação sugerida</dt><dd>{i.recommendation}</dd></div></dl>
          <div className="mt-3 flex flex-wrap items-center gap-3"><Link href={i.href} className="rounded-lg bg-emerald-500 px-3 py-1.5 text-xs font-semibold text-slate-950">Abrir</Link>
            {persistent && <ItemActions item={i} />}</div>
          {persistent && <details className="mt-3 text-xs text-slate-400"><summary className="cursor-pointer">Histórico</summary><ul className="mt-2 space-y-1">{events.filter(e => e.item_id === i.id).map((e, n) => <li key={n}>{new Date(e.created_at).toLocaleString('pt-BR')} · {EVENT[e.event] ?? e.event}{e.note ? ` — ${e.note}` : ''}</li>)}</ul></details>}
        </article>)}</div></div>
    })}
  </section>
}

function ItemActions({ item }: { item: Row }) {
  const hidden = <input type="hidden" name="item_id" value={item.id} />
  return <>
    {item.status === 'open' && <form action={decideAttention}>{hidden}<input type="hidden" name="action" value="resolve" /><SubmitButton className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs" pendingText="...">Marcar como resolvido</SubmitButton></form>}
    {item.status === 'open' && <form action={decideAttention} className="flex items-center gap-1">{hidden}<input type="hidden" name="action" value="snooze" />
      <select name="days" defaultValue="1" className={field}><option value="1">1 dia</option><option value="3">3 dias</option><option value="7">7 dias</option></select><SubmitButton className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs" pendingText="...">Adiar</SubmitButton></form>}
    {item.status === 'open' && <form action={decideAttention} className="flex items-center gap-1">{hidden}<input type="hidden" name="action" value="dismiss" />
      <input required name="note" minLength={3} maxLength={500} placeholder="Motivo para ignorar" className={field} /><SubmitButton className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs" pendingText="...">Ignorar</SubmitButton></form>}
    {item.status !== 'open' && <form action={decideAttention}>{hidden}<input type="hidden" name="action" value="reopen" /><SubmitButton className="rounded-lg border border-slate-700 px-3 py-1.5 text-xs" pendingText="...">Reabrir</SubmitButton></form>}
  </>
}
