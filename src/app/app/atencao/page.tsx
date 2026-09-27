import Link from 'next/link'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { isSeverity, SEVERITY_LABEL, SEVERITY_ORDER, type Severity } from '@/lib/attention-rules'
import { loadAttention, type AttentionRow } from '@/lib/attention.server'
import { decideAttention } from './actions'

const field = 'rounded-[8px] border border-line-strong bg-surface px-2 py-1.5 text-xs text-ink outline-none focus:border-brand'
const TONE: Record<Severity, { border: string; text: string }> = {
  critical: { border: '#F5C2C0', text: '#991B1B' },
  high: { border: '#F3D9A4', text: '#92400E' },
  medium: { border: '#BFD4EE', text: '#1E3A8A' },
  low: { border: '#D9D6CC', text: '#5B6572' },
}
const EVENT: Record<string, string> = { detected: 'Detectado', severity_changed: 'Gravidade mudou', resolved: 'Resolvido', auto_resolved: 'Resolvido sozinho (a condição acabou)', dismissed: 'Ignorado', snoozed: 'Adiado', reopened: 'Reaberto', assigned: 'Atribuído' }
const STATUS: Record<string, string> = { open: 'Aberto', snoozed: 'Adiado', dismissed: 'Ignorado', resolved: 'Resolvido' }

type Row = AttentionRow

export default async function AttentionPage() {
  const ctx = await requireAppContext()
  const { membership } = ctx
  if (!atLeast(membership.role, 'supervisor')) return <section>
    <PageHeader title="Central de atenção" />
    <Card className="p-5"><p role="alert" className="text-sm text-ink-soft">A central de atenção é restrita a supervisor, gerente e administrador.</p></Card>
  </section>

  const { persistent, items: shown, events, notEvaluated } = await loadAttention(ctx, { withEvents: true })

  return <section>
    <PageHeader title="Central de atenção" description="Sinais calculados por regras objetivas (prazos, filas, falhas). Nenhum alerta muda dados da operação: ele só mostra onde agir. Ignorar exige motivo e tudo fica no histórico." />
    {!persistent && <Card className="mb-4 p-3 text-xs text-muted">Histórico e decisões ainda não estão habilitados neste ambiente. Os sinais abaixo são calculados agora.</Card>}
    {notEvaluated.length > 0 && <p className="mb-4 rounded-[10px] border border-[#F3D9A4] bg-[#FDF3DC] px-4 py-3 text-xs text-[#92400E]">Não foi possível conferir agora: {notEvaluated.join(', ')}. Isso não significa &ldquo;zero&rdquo;.</p>}
    {!shown.length && <Card className="p-5 text-sm text-[#15803D]">Nada pendente agora.</Card>}
    {SEVERITY_ORDER.map(sev => {
      const list = shown.filter(i => (isSeverity(i.severity) ? i.severity : 'low') === sev)
      if (!list.length) return null
      return <div key={sev} className="mt-6">
        <h2 className="text-sm font-semibold uppercase tracking-wide" style={{ color: TONE[sev].text }}>{SEVERITY_LABEL[sev]} ({list.length})</h2>
        <div className="mt-2 space-y-3">{list.map(i => <Card key={i.id} className="p-5" style={{ borderColor: TONE[sev].border }}>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div><h3 className="font-medium text-ink">{i.title}</h3><p className="mt-1 text-sm text-muted">{i.reason}</p></div>
            <span className="rounded-md border border-line px-2 py-0.5 text-xs text-ink-soft">{STATUS[i.status] ?? i.status}{i.status === 'snoozed' && i.snoozed_until ? ` até ${new Date(i.snoozed_until).toLocaleDateString('pt-BR')}` : ''}</span>
          </div>
          <dl className="mt-3 grid gap-2 text-xs text-muted md:grid-cols-3">
            <div><dt className="text-ink-soft">Evidência</dt><dd>{i.evidence?.count ?? '—'} item(ns){i.evidence?.oldest_at ? `; o mais antigo desde ${new Date(i.evidence.oldest_at).toLocaleString('pt-BR')}` : ''}</dd></div>
            <div><dt className="text-ink-soft">Impacto</dt><dd>{i.impact}</dd></div>
            <div><dt className="text-ink-soft">Próxima ação sugerida</dt><dd>{i.recommendation}</dd></div>
          </dl>
          <div className="mt-3 flex flex-wrap items-center gap-3">
            <Link href={i.href} className="inline-flex h-8 items-center rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Abrir</Link>
            {persistent && <ItemActions item={i} />}
          </div>
          {persistent && <details className="mt-3 text-xs text-muted"><summary className="cursor-pointer">Histórico</summary><ul className="mt-2 space-y-1">{events.filter(e => e.item_id === i.id).map((e, n) => <li key={n}>{new Date(e.created_at).toLocaleString('pt-BR')} · {EVENT[e.event] ?? e.event}{e.note ? ` — ${e.note}` : ''}</li>)}</ul></details>}
        </Card>)}</div>
      </div>
    })}
  </section>
}

function ItemActions({ item }: { item: Row }) {
  const hidden = <input type="hidden" name="item_id" value={item.id} />
  const btn = 'inline-flex h-8 items-center rounded-[10px] border border-line bg-surface px-3 text-xs text-ink hover:bg-surface-muted'
  return <>
    {item.status === 'open' && <form action={decideAttention}>{hidden}<input type="hidden" name="action" value="resolve" /><SubmitButton className={btn} pendingText="...">Marcar como resolvido</SubmitButton></form>}
    {item.status === 'open' && <form action={decideAttention} className="flex items-center gap-1">{hidden}<input type="hidden" name="action" value="snooze" />
      <select name="days" defaultValue="1" className={field}><option value="1">1 dia</option><option value="3">3 dias</option><option value="7">7 dias</option></select><SubmitButton className={btn} pendingText="...">Adiar</SubmitButton></form>}
    {item.status === 'open' && <form action={decideAttention} className="flex items-center gap-1">{hidden}<input type="hidden" name="action" value="dismiss" />
      <input required name="note" minLength={3} maxLength={500} placeholder="Motivo para ignorar" className={field} /><SubmitButton className={btn} pendingText="...">Ignorar</SubmitButton></form>}
    {item.status !== 'open' && <form action={decideAttention}>{hidden}<input type="hidden" name="action" value="reopen" /><SubmitButton className={btn} pendingText="...">Reabrir</SubmitButton></form>}
  </>
}
