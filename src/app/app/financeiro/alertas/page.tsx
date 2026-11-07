import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { ALERT_LABEL, brlText } from '@/lib/receipts/format'

type Alert = { kind: string; proposal_id: string; reference: string; amount: string | number | null; since: string }
const PAGE = 50

// Full list behind each number of the Financeiro home (06/11/2026): the home shows only the first 20 alerts.
export default async function FinanceAlertsPage({ searchParams }: { searchParams: Promise<{ tipo?: string; pagina?: string }> }) {
  const sp = await searchParams
  const kind = sp.tipo && ALERT_LABEL[sp.tipo] ? sp.tipo : 'divergence_open'
  const page = Math.max(1, Math.min(10_000, Number.parseInt(sp.pagina ?? '1', 10) || 1))
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Financeiro" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const { data, error } = await supabase.rpc('finance_alerts', { p_org: organization.id })
  const all = ((data ?? []) as Alert[]).filter(a => a.kind === kind)
  const pages = Math.max(1, Math.ceil(all.length / PAGE))
  const list = all.slice((page - 1) * PAGE, page * PAGE)
  const href = (k: string, p = 1) => `/app/financeiro/alertas?tipo=${k}${p > 1 ? `&pagina=${p}` : ''}`

  return (
    <section>
      <PageHeader title={ALERT_LABEL[kind]} description="Lista completa. Abra o contrato para tratar cada um."
        actions={<Link href="/app/financeiro" className="text-sm text-brand hover:underline">Voltar ao financeiro</Link>} />
      <nav className="mb-4 flex flex-wrap gap-1.5 text-sm">
        {Object.keys(ALERT_LABEL).map(k => k === 'paid_without_receipt'
          ? <Link key={k} href="/app/financeiro/a-receber?dias=30" className="rounded-none border border-line bg-surface px-3 py-1.5 text-ink-soft hover:bg-surface-muted">{ALERT_LABEL[k]}</Link>
          : <Link key={k} href={href(k)} aria-current={k === kind ? 'page' : undefined} className={`rounded-none border px-3 py-1.5 ${k === kind ? 'border-ink bg-ink text-white' : 'border-line bg-surface text-ink-soft hover:bg-surface-muted'}`}>{ALERT_LABEL[k]}</Link>)}
      </nav>
      {error && <p role="alert" className="mb-4 rounded-none bg-[#FDF3DC] px-4 py-2 text-sm text-[#92400E]">Não foi possível carregar os alertas agora.</p>}
      <Card className="overflow-hidden">
        <CardHeader title={`${all.length} contrato(s)`} action={kind === 'divergence_open' ? <Link href="/app/financeiro/conciliacao" className="text-sm text-brand hover:underline">Conciliação por contrato</Link> : undefined} />
        <ul className="text-sm">
          {list.map((a, i) => (
            <li key={`${a.proposal_id}-${i}`} className="flex flex-wrap items-center justify-between gap-2 border-t border-line px-5 py-2.5">
              <span><Badge tone={a.kind === 'chargeback' ? 'reversed' : 'diverged'}>{ALERT_LABEL[a.kind]}</Badge> <Link href={`/app/propostas/${a.proposal_id}`} className="ml-2 text-ink hover:underline">{a.reference || 'Proposta'}</Link></span>
              <span className="num text-ink-soft">{a.kind === 'deferred_missing' ? `${a.amount} parcela(s)` : a.amount !== null ? brlText(String(a.amount)) : `desde ${new Date(a.since).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}`}</span>
            </li>
          ))}
          {!list.length && <li className="border-t border-line px-5 py-8 text-center text-muted">Nada aqui.</li>}
        </ul>
        {pages > 1 && (
          <nav aria-label="Páginas" className="flex items-center justify-between gap-2 border-t border-line px-4 py-3 text-sm">
            <span className="text-ink-soft">Página {page} de {pages}</span>
            <span className="flex gap-2">
              {page > 1 && <Link href={href(kind, page - 1)} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Anterior</Link>}
              {page < pages && <Link href={href(kind, page + 1)} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Próxima</Link>}
            </span>
          </nav>
        )}
      </Card>
    </section>
  )
}
