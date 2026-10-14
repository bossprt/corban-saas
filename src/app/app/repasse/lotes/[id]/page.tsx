import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { brlText } from '@/lib/receipts/format'
import { dateBr, PAYOUT_STATUS_LABEL, PAYOUT_STATUS_TONE } from '@/lib/payout/format'
import { batchStatus, type BatchDetail } from '@/lib/payout/batches'
import { PrintButton } from '@/components/PrintButton'
import { reverseBatch } from '../../actions'

const box = 'rounded-[14px] border border-line bg-surface px-4 py-3'
const btn = 'inline-flex h-9 items-center rounded-[10px] border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted print:hidden'

// One payment batch: header, one line per person paid with the contracts a closing paid, Excel, print and "Desfazer lote".
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
          <PrintButton className={btn} />
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

      <Card className="mb-4 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-sm">
            <thead className="bg-surface-muted text-xs font-semibold text-muted">
              <tr><th className="px-4 py-2.5">Pessoa</th><th className="px-4 py-2.5">Contratos</th><th className="px-4 py-2.5 text-right">Valor pago</th><th className="px-4 py-2.5">Situação</th></tr>
            </thead>
            <tbody>
              {b.lines.map(l => (
                <tr key={l.payout_id} className="border-t border-line align-top">
                  <td className="px-4 py-2.5"><Link href={`/app/repasse/${l.account_id}`} className="font-medium text-ink hover:underline print:no-underline">{l.holder}</Link></td>
                  <td className="px-4 py-2.5 text-[13px] text-ink-soft">
                    {l.contracts.length ? l.contracts.map(c => (
                      <div key={c.proposal_id}><Link href={`/app/propostas/${c.proposal_id}`} className="hover:underline">{c.ade ?? 'sem ADE'}</Link>{c.client ? ` · ${c.client}` : ''} · {brlText(c.amount)}</div>
                    )) : <span className="text-muted">{l.kind === 'withdrawal' ? 'Saque do saldo' : l.status === 'reversed' ? 'Contratos voltaram para o próximo pagamento' : '—'}</span>}
                  </td>
                  <td className="num px-4 py-2.5 text-right font-semibold text-ink">{brlText(l.amount)}</td>
                  <td className="px-4 py-2.5"><Badge tone={PAYOUT_STATUS_TONE[l.status]}>{PAYOUT_STATUS_LABEL[l.status]}</Badge>{l.reversal_reason && <div className="text-xs text-muted">Motivo: {l.reversal_reason}</div>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

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
