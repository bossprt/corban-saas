import Link from 'next/link'
import { Badge, ButtonLink, Card, CardHeader, Kpi, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { ALERT_LABEL, brlText, REPORT_KIND_LABEL, REPORT_STATUS_LABEL } from '@/lib/receipts/format'

type Report = { id: string; source_kind: string; source_id: string; report_kind: string; reference_month: string; file_name: string; line_count: number; lines_total: string; status: string; created_at: string }
type Alert = { kind: string; proposal_id: string; reference: string; amount: string | null; since: string }

// Finance home: alerts of the receipt reconciliation and the imported reports.
export default async function FinancePage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Financeiro" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const [{ data: reports }, { data: alerts }, { data: banks }, { data: providers }] = await Promise.all([
    supabase.from('receipt_reports').select('id,source_kind,source_id,report_kind,reference_month,file_name,line_count,lines_total,status,created_at').neq('status', 'discarded').order('created_at', { ascending: false }).limit(100),
    supabase.rpc('finance_alerts', { p_org: organization.id }),
    supabase.from('organization_banks').select('id,name'),
    supabase.from('organization_providers').select('id,name'),
  ])
  const names = new Map([...(banks ?? []), ...(providers ?? [])].map(x => [x.id, x.name]))
  const list = (alerts ?? []) as Alert[]
  const count = (k: string) => list.filter(a => a.kind === k).length

  return (
    <section>
      <PageHeader title="Financeiro" description="Recebimento da comissão dos bancos e promotoras, conferido contrato a contrato."
        actions={can(access, 'financeiro.edit') ? <ButtonLink href="/app/financeiro/importar">Importar relatório</ButtonLink> : undefined} />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {Object.keys(ALERT_LABEL).map(k => <Kpi key={k} label={ALERT_LABEL[k]} value={count(k)} />)}
      </div>

      {list.length > 0 && (
        <Card className="mb-4">
          <CardHeader title="Precisa de atenção" action={<Link href="/app/financeiro/conciliacao" className="text-sm text-brand hover:underline">Conciliação por contrato</Link>} />
          <ul className="px-2 pb-3 text-sm">
            {list.slice(0, 20).map((a, i) => (
              <li key={`${a.kind}-${a.proposal_id}-${i}`} className="flex flex-wrap items-center justify-between gap-2 border-t border-line px-3 py-2 first:border-t-0">
                <span><Badge tone={a.kind === 'chargeback' ? 'reversed' : 'diverged'}>{ALERT_LABEL[a.kind]}</Badge> <Link href={`/app/propostas/${a.proposal_id}`} className="ml-2 text-ink hover:underline">{a.reference || 'Proposta'}</Link></span>
                <span className="num text-ink-soft">{a.kind === 'deferred_missing' ? `${a.amount} parcela(s)` : a.amount !== null ? brlText(a.amount) : `desde ${new Date(a.since).toLocaleDateString('pt-BR')}`}</span>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <Card className="overflow-hidden">
        <CardHeader title="Relatórios importados" />
        <table className="w-full text-left text-sm">
          <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr><th className="px-4 py-2.5">Fonte</th><th className="px-4 py-2.5">Tipo</th><th className="px-4 py-2.5">Mês</th><th className="px-4 py-2.5">Arquivo</th><th className="px-4 py-2.5 text-right">Linhas</th><th className="px-4 py-2.5 text-right">Total</th><th className="px-4 py-2.5">Situação</th></tr></thead>
          <tbody>
            {((reports ?? []) as Report[]).map(r => (
              <tr key={r.id} className="border-t border-line hover:bg-surface-muted">
                <td className="px-4 py-2.5"><Link href={`/app/financeiro/relatorios/${r.id}`} className="font-medium text-ink hover:underline">{names.get(r.source_id) ?? '—'}</Link></td>
                <td className="px-4 py-2.5">{REPORT_KIND_LABEL[r.report_kind]}</td>
                <td className="px-4 py-2.5">{r.reference_month.slice(5, 7)}/{r.reference_month.slice(0, 4)}</td>
                <td className="max-w-[220px] truncate px-4 py-2.5 text-ink-soft">{r.file_name}</td>
                <td className="num px-4 py-2.5 text-right">{r.line_count}</td>
                <td className="num px-4 py-2.5 text-right">{brlText(r.lines_total)}</td>
                <td className="px-4 py-2.5"><Badge tone={r.status === 'confirmed' ? 'received' : 'pending'}>{REPORT_STATUS_LABEL[r.status]}</Badge></td>
              </tr>
            ))}
            {!(reports ?? []).length && <tr><td colSpan={7} className="px-4 py-8 text-center text-muted">Nenhum relatório importado ainda.</td></tr>}
          </tbody>
        </table>
      </Card>
    </section>
  )
}
