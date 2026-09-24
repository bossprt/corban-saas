import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { fromDecimalString, isZero, sub, toDecimalString } from '@/lib/commission/money'
import { brlText, LINE_STATUS_LABEL, LINE_STATUS_TONE, REPORT_KIND_LABEL, REPORT_STATUS_LABEL } from '@/lib/receipts/format'
import { ignoreLine, linkLine, reportAction } from '../../actions'

type Line = { id: string; row_number: number; ade: string; installment_number: number | null; assigned_installment: number | null; amount: string; expected_amount: string | null; status: string; note: string | null; proposal_id: string | null; matched_by: string | null }
const OPEN = ['not_found', 'ambiguous', 'duplicate', 'no_calc', 'installment_invalid']
const FILTERS: [string, string][] = [['todas', 'Todas'], ['resolver', 'A resolver'], ['divergent', 'Divergem'], ['ok', 'Conferem'], ['ignored', 'Ignoradas']]

// One imported report: line by line against the frozen commission. Unresolved lines are linked or ignored; then finance confirms.
export default async function ReceiptReportPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ ver?: string }> }) {
  const { id } = await params
  const { ver = 'todas' } = await searchParams
  if (!isUuid(id)) notFound()
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) notFound()
  const { data: rep } = await supabase.from('receipt_reports').select('id,source_kind,source_id,report_kind,reference_month,file_name,declared_total,line_count,lines_total,status,created_at,confirmed_at').eq('id', id).maybeSingle()
  if (!rep) notFound()
  const [{ data: lineRows }, { data: source }] = await Promise.all([
    supabase.from('receipt_lines').select('id,row_number,ade,installment_number,assigned_installment,amount,expected_amount,status,note,proposal_id,matched_by').eq('report_id', id).order('row_number').limit(5000),
    supabase.from(rep.source_kind === 'bank' ? 'organization_banks' : 'organization_providers').select('name').eq('id', rep.source_id).maybeSingle(),
  ])
  const lines = (lineRows ?? []) as Line[]
  const draft = rep.status === 'draft'
  const canEdit = draft && can(access, 'financeiro.edit')
  const canConfirm = draft && can(access, 'financeiro.approve')
  const count = (s: string[]) => lines.filter(l => s.includes(l.status)).length
  const open = count(OPEN)
  const shown = lines.filter(l => ver === 'todas' || (ver === 'resolver' ? OPEN.includes(l.status) : l.status === ver))
  const totalOk = rep.declared_total === null || rep.declared_total === rep.lines_total
  const deferred = rep.report_kind === 'deferred'

  return (
    <section>
      <PageHeader
        title={`${source?.name ?? 'Fonte'} · ${REPORT_KIND_LABEL[rep.report_kind]} · ${rep.reference_month.slice(5, 7)}/${rep.reference_month.slice(0, 4)}`}
        description={<>Arquivo {rep.file_name}. <Link href="/app/financeiro" className="text-brand hover:underline">Voltar ao financeiro</Link></>}
        actions={<Badge tone={rep.status === 'confirmed' ? 'received' : rep.status === 'draft' ? 'pending' : 'neutral'}>{REPORT_STATUS_LABEL[rep.status]}</Badge>}
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-4">
        {[['Linhas', String(rep.line_count)], ['Total das linhas', brlText(rep.lines_total)], ['Total informado', rep.declared_total === null ? 'não informado' : brlText(rep.declared_total)], ['A resolver', String(open)]].map(([k, v]) => (
          <div key={k} className="rounded-[14px] border border-line bg-surface px-5 py-4"><div className="text-[13px] text-muted">{k}</div><div className="num mt-1 text-xl font-semibold text-ink">{v}</div></div>
        ))}
      </div>

      {draft && (
        <Card className="mb-4 p-5 text-sm">
          <p className="text-ink-soft">
            Confere: {count(['ok'])} · Diverge: {count(['divergent'])} · A resolver: {open} · Ignoradas: {count(['ignored'])}.
            {!totalOk && <span className="ml-1 font-medium text-[#991B1B]">O total informado não bate com a soma das linhas.</span>}
            {' '}Divergências entram como recebidas e ficam em aberto na conciliação até alguém aceitar com o motivo.
          </p>
          <div className="mt-3 flex flex-wrap gap-2">
            {canEdit && <form action={reportAction}><input type="hidden" name="report_id" value={id} /><input type="hidden" name="op" value="rematch" /><button className="h-9 rounded-[10px] border border-line bg-surface px-3 text-sm hover:bg-surface-muted">Comparar de novo</button></form>}
            {canConfirm && <form action={reportAction}><input type="hidden" name="report_id" value={id} /><input type="hidden" name="op" value="confirm" /><button disabled={open > 0 || !totalOk} className="h-9 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">Confirmar e lançar recebimentos</button></form>}
            {canEdit && <form action={reportAction}><input type="hidden" name="report_id" value={id} /><input type="hidden" name="op" value="discard" /><button className="h-9 rounded-[10px] px-3 text-sm text-ink-soft hover:bg-surface-muted">Descartar relatório</button></form>}
          </div>
        </Card>
      )}

      <Card className="overflow-hidden">
        <CardHeader title="Linhas" action={
          <nav className="flex flex-wrap gap-1 text-[13px]">
            {FILTERS.map(([k, label]) => <Link key={k} href={`?ver=${k}`} className={`rounded-md px-2 py-1 ${ver === k ? 'bg-brand-soft font-semibold text-brand-strong' : 'text-ink-soft hover:bg-surface-muted'}`}>{label}</Link>)}
          </nav>
        } />
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr>
              <th className="px-3 py-2">Linha</th><th className="px-3 py-2">Contrato</th>{deferred && <th className="px-3 py-2">Parcela</th>}
              <th className="px-3 py-2 text-right">Recebido</th><th className="px-3 py-2 text-right">Esperado</th><th className="px-3 py-2 text-right">Diferença</th><th className="px-3 py-2">Situação</th>{canEdit && <th className="px-3 py-2">Resolver</th>}
            </tr></thead>
            <tbody>
              {shown.map(l => {
                const diff = l.expected_amount === null ? null : sub(fromDecimalString(String(l.amount)), fromDecimalString(String(l.expected_amount)))
                return (
                  <tr key={l.id} className="border-t border-line align-top">
                    <td className="num px-3 py-2 text-muted">{l.row_number}</td>
                    <td className="px-3 py-2">{l.proposal_id ? <Link href={`/app/propostas/${l.proposal_id}`} className="text-ink hover:underline">{l.ade}</Link> : l.ade}{l.matched_by === 'manual' && <span className="ml-1 text-xs text-muted">(vinculada)</span>}</td>
                    {deferred && <td className="num px-3 py-2">{l.assigned_installment ?? l.installment_number ?? '—'}</td>}
                    <td className="num px-3 py-2 text-right">{brlText(l.amount)}</td>
                    <td className="num px-3 py-2 text-right text-ink-soft">{brlText(l.expected_amount)}</td>
                    <td className={`num px-3 py-2 text-right ${diff && !isZero(diff) ? 'font-medium text-[#92400E]' : 'text-muted'}`}>{diff === null ? '—' : brlText(toDecimalString(diff, 2))}</td>
                    <td className="px-3 py-2"><Badge tone={LINE_STATUS_TONE[l.status]}>{LINE_STATUS_LABEL[l.status]}</Badge>{l.note && <div className="mt-1 text-xs text-muted">{l.note}</div>}</td>
                    {canEdit && (
                      <td className="px-3 py-2">
                        {l.status !== 'ignored' && l.status !== 'ok' && (
                          <div className="flex flex-col gap-1.5">
                            <form action={linkLine} className="flex gap-1"><input type="hidden" name="report_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                              <input name="ade" placeholder="ADE da proposta certa" required className="field h-8 w-40 text-xs" /><button className="h-8 rounded-md border border-line px-2 text-xs hover:bg-surface-muted">Vincular</button></form>
                            <form action={ignoreLine} className="flex gap-1"><input type="hidden" name="report_id" value={id} /><input type="hidden" name="line_id" value={l.id} />
                              <input name="note" placeholder="Motivo" required minLength={3} className="field h-8 w-40 text-xs" /><button className="h-8 rounded-md px-2 text-xs text-ink-soft hover:bg-surface-muted">Ignorar</button></form>
                          </div>
                        )}
                      </td>
                    )}
                  </tr>
                )
              })}
              {!shown.length && <tr><td colSpan={8} className="px-3 py-8 text-center text-muted">Nenhuma linha neste filtro.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
