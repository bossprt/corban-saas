import Link from 'next/link'
import { Badge, Card, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brlText } from '@/lib/receipts/format'
import { dateBr } from '@/lib/payout/format'
import { batchStatus, type BatchRow } from '@/lib/payout/batches'

// Payment batches (owner request 13/10/2026, like the NASP "Lotes de pagamento de comissões"): every confirmation of
// seller payments, newest first. Opening one shows who was paid and lets an administrator undo the whole batch.
export default async function PayoutBatchesPage() {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'repasse.view')) {
    return <section><PageHeader title="Lotes de pagamento" /><Card className="p-5 text-sm text-ink-soft">Sem permissão para ver os pagamentos.</Card></section>
  }
  const { data } = await supabase.rpc('payout_batch_list', { p_org: organization.id, p_limit: 300 })
  const rows = (data ?? []) as BatchRow[]
  return (
    <section>
      <PageHeader title="Lotes de pagamento" description="Cada confirmação de pagamento de vendedores. Abra um lote para ver quem foi pago, baixar o Excel ou desfazer."
        actions={<Link href="/app/repasse" className="inline-flex h-9 items-center rounded-[10px] border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted">Voltar</Link>} />
      <Card className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="bg-surface-muted text-xs font-semibold text-muted">
              <tr><th className="px-4 py-2.5">Data</th><th className="px-4 py-2.5 text-right">Qtd</th><th className="px-4 py-2.5 text-right">Valor total</th><th className="px-4 py-2.5">Conta que pagou</th><th className="px-4 py-2.5">Comprovante</th><th className="px-4 py-2.5">Pago por</th><th className="px-4 py-2.5">Situação</th></tr>
            </thead>
            <tbody>
              {rows.map(b => {
                const st = batchStatus(b)
                return (
                  <tr key={b.id} className="border-t border-line">
                    <td className="num px-4 py-2.5"><Link href={`/app/repasse/lotes/${b.id}`} className="font-medium text-brand hover:underline">{dateBr(b.paid_on)}</Link></td>
                    <td className="num px-4 py-2.5 text-right">{b.payouts}</td>
                    <td className="num px-4 py-2.5 text-right font-semibold text-ink">{brlText(b.total)}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{b.bank_accounts ?? '—'}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{b.payment_reference ?? '—'}</td>
                    <td className="px-4 py-2.5 text-ink-soft">{b.paid_by ?? '—'}</td>
                    <td className="px-4 py-2.5"><Badge tone={st.tone}>{st.label}</Badge></td>
                  </tr>
                )
              })}
              {!rows.length && <tr><td colSpan={7} className="px-4 py-8 text-center text-muted">Nenhum pagamento registrado.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
