import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { brlText } from '@/lib/receipts/format'
import { dateBr, PAYOUT_STATUS_LABEL, PAYOUT_STATUS_TONE } from '@/lib/payout/format'
import { batchItemLabel, batchStatus, type BatchDetail } from '@/lib/payout/batches'
import { Printer } from 'lucide-react'
import { formatTaxId } from '@/lib/sellers'
import { payTo } from '@/app/imprimir/sheets'
import { reverseBatch } from '../../actions'

const box = 'rounded-[14px] border border-line bg-surface px-4 py-3'
const btn = 'inline-flex h-9 items-center rounded-[10px] border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted print:hidden'

// One payment batch: header, one line per person paid with the contracts the payment paid (a payment from the balance
// covers the oldest contracts first), Excel, print and "Desfazer lote".
export default async function PayoutBatchPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, access, membership } = await requireAppContext()
  if (!can(access, 'repasse.view')) notFound()
  const { data, error } = await supabase.rpc('payout_batch_detail', { p_batch: id })
  if (error || !data) notFound()
  const b = data as BatchDetail
  const undone = b.lines.filter(l => l.status === 'reversed').length
  const st = batchStatus({ payouts: b.lines.length, undone })
  const stillPaid = b.lines.some(l => l.status === 'paid')

  return (
    <section>
      <PageHeader title={`Lote de pagamento · ${dateBr(b.paid_on)}`}
        actions={<>
          <Link href="/app/repasse/lotes" className={btn}>Voltar</Link>
          <a href={`/api/repasse/lotes/${b.id}`} download className={btn}>Excel</a>
          <Link href={`/imprimir/lote/${b.id}`} className={`${btn} border-brand font-semibold text-brand`}><Printer size={15} className="mr-1.5" aria-hidden />Imprimir lote</Link>
        </>} />

      <div className="mb-4 grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <div className={box}><div className="text-xs text-muted">Pagamento dia</div><div className="num mt-1 font-semibold text-ink">{dateBr(b.paid_on)}</div></div>
        <div className={box}><div className="text-xs text-muted">Pessoas pagas</div><div className="num mt-1 font-semibold text-ink">{b.lines.length}</div></div>
        <div className={box}><div className="text-xs text-muted">Valor total</div><div className="num mt-1 font-semibold text-ink">{brlText(b.total)}</div></div>
        <div className={box}><div className="text-xs text-muted">Conta que pagou</div><div className="mt-1 font-semibold text-ink">{b.bank_accounts ?? '—'}</div></div>
        <div className={box}><div className="text-xs text-muted">Comprovante · pago por</div><div className="mt-1 text-sm text-ink">{b.payment_reference ?? '—'} · {b.paid_by ?? '—'}</div></div>
        <div className={box}><div className="text-xs text-muted">Situação</div><div className="mt-1"><Badge tone={st.tone}>{st.label}</Badge></div></div>
      </div>
      {b.reversed_at && <p className="mb-4 rounded-[10px] bg-surface-muted px-4 py-2 text-sm text-ink-soft">Desfeito por {b.reversed_by ?? '—'} em {dateBr(b.reversed_at.slice(0, 10))}. Motivo: {b.reversal_reason}</p>}

      {/* One block per person (owner, 21/10/2026: the contracts as a table, not loose text). */}
      <div className="mb-4 grid gap-3">
        {b.lines.map(l => (
          <Card key={l.payout_id} className="overflow-hidden">
            <div className="flex flex-wrap items-start justify-between gap-3 border-b border-line px-4 py-3">
              <div className="min-w-0">
                <Link href={`/app/repasse/${l.account_id}`} className="font-semibold text-ink hover:underline">{l.holder}</Link>
                <div className="text-xs text-muted">{[l.holder_document ? formatTaxId(l.holder_document) : 'CPF/CNPJ não cadastrado', payTo(l.pay_target)].join(' · ')}</div>
              </div>
              <div className="flex items-center gap-3">
                <Badge tone={PAYOUT_STATUS_TONE[l.status]}>{PAYOUT_STATUS_LABEL[l.status]}</Badge>
                <span className="num text-base font-semibold text-ink">{brlText(l.amount)}</span>
                {l.status === 'paid' && <Link href={`/imprimir/lote/${b.id}?pessoa=${l.payout_id}`} className="text-sm text-brand hover:underline">Demonstrativo</Link>}
              </div>
            </div>
            {l.reversal_reason && <p className="px-4 pt-2 text-xs text-muted">Motivo: {l.reversal_reason}</p>}
            {l.contracts.length ? (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[720px] text-left text-[13px]">
                  <thead className="bg-surface-muted text-xs font-semibold text-muted">
                    <tr><th className="px-4 py-2">Contrato</th><th className="px-4 py-2">Cliente</th><th className="px-4 py-2">Banco · convênio · produto</th><th className="px-4 py-2 text-right">Liberado</th><th className="px-4 py-2">Pago ao cliente</th><th className="px-4 py-2 text-right">Comissão</th></tr>
                  </thead>
                  <tbody>
                    {l.contracts.map((c, k) => (
                      <tr key={`${c.proposal_id ?? c.kind}-${k}`} className="border-t border-line">
                        <td className="px-4 py-2">{c.proposal_id ? <Link href={`/app/propostas/${c.proposal_id}`} className="hover:underline">{batchItemLabel(c)}</Link> : batchItemLabel(c)}</td>
                        <td className="px-4 py-2 text-ink-soft">{c.client ?? ''}</td>
                        <td className="px-4 py-2 text-ink-soft">{[c.bank, c.agreement, c.product].filter(Boolean).join(' · ')}</td>
                        <td className="num px-4 py-2 text-right text-ink-soft">{c.released ? brlText(c.released) : '—'}</td>
                        <td className="px-4 py-2 text-ink-soft">{c.paid_to_client_on ? dateBr(c.paid_to_client_on) : '—'}</td>
                        <td className="num px-4 py-2 text-right font-medium text-ink">{brlText(c.amount)}{c.partial && <span className="ml-1 text-xs text-[#92400E]">(em parte)</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <p className="px-4 py-3 text-sm text-muted">{l.kind === 'withdrawal' ? 'Saque do saldo' : l.status === 'reversed' ? 'Contratos voltaram para o próximo pagamento' : 'Sem contratos'}</p>}
          </Card>
        ))}
      </div>

      {membership.role === 'admin' && stillPaid && (
        <Card className="p-5 print:hidden">
          <details>
            <summary className="cursor-pointer text-sm font-semibold text-[#991B1B]">Desfazer lote</summary>
            <form action={reverseBatch} className="mt-3 grid max-w-xl gap-2">
              <input type="hidden" name="batch_id" value={b.id} />
              <p className="text-sm text-ink-soft">Use quando os pagamentos foram registrados aqui mas não foram feitos no banco. Todos os pagamentos ainda pagos deste lote são desfeitos: os valores voltam ao saldo de cada pessoa e as saídas do banco são anuladas. Nada é apagado.</p>
              <input name="reason" required minLength={3} maxLength={300} placeholder="Motivo (ex.: PIX não foram feitos)" className="field" />
              <button className="h-10 w-fit rounded-[10px] bg-[#991B1B] px-4 text-sm font-semibold text-white hover:opacity-90">Sim, desfazer o lote</button>
            </form>
          </details>
        </Card>
      )}
    </section>
  )
}
