import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge, Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { brlText } from '@/lib/receipts/format'
import { dateBr, PAYOUT_STATUS_LABEL, PAYOUT_STATUS_TONE } from '@/lib/payout/format'
import type { Breakdown } from '@/lib/payout/batches'
import { PayoutBreakdown } from '../../PayoutBreakdown'

type PayoutBreakdownRow = Breakdown & {
  payout_id: string; account_id: string; holder: string; kind: string; status: string; amount: string; paid_on: string | null
  payment_reference: string | null; period_start: string | null; period_end: string | null; requested_at: string; batch_id: string | null; note: string | null
}
const box = 'rounded-[14px] border border-line bg-surface px-4 py-3'
const btn = 'inline-flex h-9 items-center rounded-[10px] border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted'

// "Ver contratos" of one payment (owner, 06/11/2026): every payment, in a batch or not ("Pagar agora", "Marcar pago"),
// with the contracts it pays and the composition of its amount. Finance, or the person (own payments); the database decides.
export default async function PayoutPaymentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase } = await requireAppContext()
  const { data, error } = await supabase.rpc('payout_breakdown', { p_payout: id })
  if (error || !data) notFound()
  const p = data as PayoutBreakdownRow
  const kind = p.kind === 'closing' ? `Fechamento até ${dateBr(p.period_end)}` : 'Saque do saldo'

  return (
    <section>
      <PageHeader title={`Contratos do pagamento · ${p.holder}`} description={kind}
        actions={<>
          <Link href={`/app/repasse/${p.account_id}`} className={btn}>Voltar à conta</Link>
          {p.batch_id && <Link href={`/app/repasse/lotes/${p.batch_id}`} className={btn}>Ver lote</Link>}
          {p.status === 'paid' && p.paid_on && <Link href={`/imprimir/pessoa/${p.account_id}?de=${p.paid_on}&ate=${p.paid_on}`} className={btn}>Imprimir</Link>}
        </>} />
      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className={box}><div className="text-xs text-muted">Valor</div><div className="num mt-1 font-semibold text-ink">{brlText(p.amount)}</div></div>
        <div className={box}><div className="text-xs text-muted">Situação</div><div className="mt-1"><Badge tone={PAYOUT_STATUS_TONE[p.status]}>{PAYOUT_STATUS_LABEL[p.status] ?? p.status}</Badge></div></div>
        <div className={box}><div className="text-xs text-muted">Pago em</div><div className="num mt-1 font-semibold text-ink">{dateBr(p.paid_on)}</div></div>
        <div className={box}><div className="text-xs text-muted">Comprovante</div><div className="mt-1 text-sm text-ink">{p.payment_reference ?? '—'}</div></div>
      </div>
      {p.status !== 'paid' && !p.undone && <p className="mb-4 rounded-[10px] bg-surface-muted px-4 py-2 text-sm text-ink-soft">Ainda não pago: é o que será pago ao marcar como pago.</p>}
      <Card className="overflow-hidden">
        <PayoutBreakdown b={p} total={p.amount} empty={p.kind === 'withdrawal' ? 'Saque do saldo sem contratos' : 'Sem contratos'} />
      </Card>
    </section>
  )
}
