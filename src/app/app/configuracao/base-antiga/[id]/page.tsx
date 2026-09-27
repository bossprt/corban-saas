import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import { brlText } from '@/lib/receipts/format'
import { LEGACY_ISSUE_LABEL, LEGACY_STATUS } from '@/lib/legacy/fields'
import { confirmLegacyBatch, discardLegacyBatch, undoLegacyBatch } from '../actions'

const day = (d: string | null) => (d ? new Date(`${d.slice(0, 10)}T12:00:00Z`).toLocaleDateString('pt-BR') : '—')
// CPF shown masked: only the last digits identify the row on screen.
const maskCpf = (c: string | null) => (c && c.length === 11 ? `***.***.${c.slice(6, 9)}-${c.slice(9)}` : c ?? '—')

// Preview of one batch: what enters, what is refused and why; confirm, discard or undo.
export default async function LegacyBatchPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) notFound()
  const { data: b } = await supabase.from('legacy_import_batches').select('*').eq('id', id).maybeSingle()
  if (!b) notFound()
  const [{ data: issues }, { data: sample }, ...byIssue] = await Promise.all([
    supabase.from('legacy_import_rows').select('row_number,cpf,full_name,ade,contract_on,issue').eq('batch_id', id).not('issue', 'is', null).order('row_number').limit(200),
    supabase.from('legacy_import_rows').select('row_number,cpf,full_name,bank_name,ade,contract_on,requested_amount,seller_name').eq('batch_id', id).is('issue', null).order('row_number').limit(20),
    // One exact count per reason (a batch can have tens of thousands of lines; row reads stop at 1.000).
    ...Object.keys(LEGACY_ISSUE_LABEL).map(k => supabase.from('legacy_import_rows').select('*', { count: 'exact', head: true }).eq('batch_id', id).eq('issue', k)),
  ])
  const count = new Map<string, number>()
  Object.keys(LEGACY_ISSUE_LABEL).forEach((k, i) => { const n = byIssue[i]?.count ?? 0; if (n) count.set(k, n) })
  const ok = b.rows_total - b.rows_with_issue
  const st = LEGACY_STATUS[b.status] ?? { label: b.status, tone: 'neutral' as const }

  return (
    <section>
      <Link href="/app/configuracao/base-antiga" className="text-sm text-brand hover:underline">← Base antiga</Link>
      <PageHeader title={b.file_name} description={`Origem ${b.source_system} · data de corte ${day(b.cutoff_on)} · enviado em ${day(b.created_at)}`} />
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <Badge tone={st.tone}>{st.label}</Badge>
        <span className="text-sm text-ink-soft">{b.rows_total} linha(s): <strong className="text-ink">{ok}</strong> entram{b.rows_with_issue ? <>, <strong className="text-ink">{b.rows_with_issue}</strong> ficam de fora</> : null}.</span>
        {b.status !== 'draft' && b.status !== 'discarded' && <span className="text-sm text-ink-soft">{b.clients_created} cliente(s) novo(s), {b.clients_matched} já existente(s), {b.contracts_created} contrato(s).</span>}
      </div>

      {b.status === 'draft' && (
        <Card className="mb-4 flex flex-wrap items-center justify-between gap-3 p-5">
          <p className="text-sm text-ink-soft">Nada foi gravado ainda. Confirme para trazer as {ok} linha(s) sem problema; as outras ficam de fora.</p>
          <div className="flex gap-2">
            <form action={discardLegacyBatch}><input type="hidden" name="batch_id" value={b.id} /><SubmitButton className="h-10 rounded-[10px] border border-line px-4 text-sm hover:bg-surface-muted" pendingText="...">Descartar</SubmitButton></form>
            {ok > 0 && <form action={confirmLegacyBatch}><input type="hidden" name="batch_id" value={b.id} /><SubmitButton className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Importando...">Confirmar importação</SubmitButton></form>}
          </div>
        </Card>
      )}
      {b.status === 'confirmed' && membership.role === 'admin' && (
        <Card className="mb-4 p-5">
          <details>
            <summary className="cursor-pointer text-sm text-ink-soft underline">Desfazer esta importação</summary>
            <form action={undoLegacyBatch} className="mt-3 flex flex-wrap items-end gap-2">
              <input type="hidden" name="batch_id" value={b.id} />
              <label className="text-[13px] font-medium text-ink-soft">Motivo<input name="reason" required minLength={3} maxLength={300} className="field mt-1.5" /></label>
              <SubmitButton className="h-10 rounded-[10px] border border-[#F5C2C0] px-4 text-sm text-[#991B1B] hover:bg-[#FDE2E1]" pendingText="...">Desfazer</SubmitButton>
            </form>
            <p className="mt-2 text-xs text-muted">Os contratos saem; os clientes criados por esta importação saem se nada mais aconteceu com eles. Clientes que já existiam ficam como estão.</p>
          </details>
        </Card>
      )}
      {b.status === 'undone' && <Card className="mb-4 p-5 text-sm text-ink-soft">Desfeita em {day(b.undone_at)}. Motivo: {b.undo_reason}</Card>}

      {(issues ?? []).length > 0 && (
        <Card className="mb-4 overflow-hidden">
          <CardHeader title="Linhas que ficam de fora" />
          <p className="px-5 pb-3 text-sm text-ink-soft">{[...count].map(([k, n]) => `${LEGACY_ISSUE_LABEL[k] ?? k}: ${n}`).join(' · ')}</p>
          <table className="w-full text-left text-sm">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-4 py-2">Linha</th><th className="px-4 py-2">CPF</th><th className="px-4 py-2">Nome</th><th className="px-4 py-2">Contrato</th><th className="px-4 py-2">Data</th><th className="px-4 py-2">Motivo</th></tr></thead>
            <tbody>{(issues ?? []).map(r => (
              <tr key={r.row_number} className="border-t border-line">
                <td className="px-4 py-1.5">{r.row_number}</td><td className="px-4 py-1.5">{maskCpf(r.cpf)}</td><td className="px-4 py-1.5">{r.full_name ?? '—'}</td>
                <td className="px-4 py-1.5">{r.ade ?? '—'}</td><td className="px-4 py-1.5">{day(r.contract_on)}</td><td className="px-4 py-1.5">{LEGACY_ISSUE_LABEL[r.issue as string] ?? r.issue}</td>
              </tr>
            ))}</tbody>
          </table>
        </Card>
      )}

      {b.status === 'draft' && (sample ?? []).length > 0 && (
        <Card className="overflow-hidden">
          <CardHeader title="Primeiras linhas que entram" />
          <table className="w-full text-left text-sm">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-4 py-2">Linha</th><th className="px-4 py-2">CPF</th><th className="px-4 py-2">Nome</th><th className="px-4 py-2">Banco</th><th className="px-4 py-2">Contrato</th><th className="px-4 py-2">Data</th><th className="px-4 py-2 text-right">Valor</th><th className="px-4 py-2">Vendedor</th></tr></thead>
            <tbody>{(sample ?? []).map(r => (
              <tr key={r.row_number} className="border-t border-line">
                <td className="px-4 py-1.5">{r.row_number}</td><td className="px-4 py-1.5">{maskCpf(r.cpf)}</td><td className="px-4 py-1.5">{r.full_name ?? '—'}</td><td className="px-4 py-1.5">{r.bank_name ?? '—'}</td>
                <td className="px-4 py-1.5">{r.ade ?? '—'}</td><td className="px-4 py-1.5">{day(r.contract_on)}</td><td className="px-4 py-1.5 text-right">{r.requested_amount === null ? '—' : brlText(r.requested_amount)}</td><td className="px-4 py-1.5">{r.seller_name ?? '—'}</td>
              </tr>
            ))}</tbody>
          </table>
        </Card>
      )}
    </section>
  )
}
