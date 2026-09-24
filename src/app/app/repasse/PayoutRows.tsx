import Link from 'next/link'
import { Badge } from '@/components/ui'
import { brlText } from '@/lib/receipts/format'
import { dateBr, PAYOUT_STATUS_LABEL, PAYOUT_STATUS_TONE } from '@/lib/payout/format'
import { decidePayout, markPaid } from './actions'

const todayIso = () => new Date().toISOString().slice(0, 10)

export type PayoutRow = { id: string; account_id: string; kind: string; period_start: string | null; period_end: string | null; carry_in: string | null; period_net: string | null; debt_deduction: string | null; amount: string; carry_out: string | null; status: string; requested_at: string; paid_on: string | null; payment_reference: string | null; note: string | null }

// Statements and withdrawals with their approval and payment actions (the database enforces who may do what).
export function PayoutRows({ rows, names, back, canApprove, canPay }: { rows: PayoutRow[]; names?: Map<string, string>; back: string; canApprove: boolean; canPay: boolean }) {
  const today = todayIso()
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-[13px]">
        <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr>
          {names && <th className="px-3 py-2">Pessoa</th>}<th className="px-3 py-2">Tipo</th><th className="px-3 py-2 text-right">Saldo anterior</th><th className="px-3 py-2 text-right">Movimento</th>
          <th className="px-3 py-2 text-right">Desconto do negativo</th><th className="px-3 py-2 text-right">A pagar</th><th className="px-3 py-2 text-right">Saldo seguinte</th><th className="px-3 py-2">Situação</th><th className="px-3 py-2">Ação</th>
        </tr></thead>
        <tbody>
          {rows.map(p => (
            <tr key={p.id} className="border-t border-line align-top">
              {names && <td className="px-3 py-2"><Link href={`/app/repasse/${p.account_id}`} className="text-ink hover:underline">{names.get(p.account_id) ?? 'Conta'}</Link></td>}
              <td className="px-3 py-2">{p.kind === 'closing' ? `Fechamento até ${dateBr(p.period_end)}` : 'Saque'}{p.note && <div className="text-xs text-muted">{p.note}</div>}</td>
              <td className="num px-3 py-2 text-right">{brlText(p.carry_in)}</td>
              <td className="num px-3 py-2 text-right">{brlText(p.period_net)}</td>
              <td className="num px-3 py-2 text-right">{brlText(p.debt_deduction)}</td>
              <td className="num px-3 py-2 text-right font-semibold text-ink">{brlText(p.amount)}</td>
              <td className="num px-3 py-2 text-right">{brlText(p.carry_out)}</td>
              <td className="px-3 py-2"><Badge tone={PAYOUT_STATUS_TONE[p.status]}>{PAYOUT_STATUS_LABEL[p.status]}</Badge>{p.status === 'paid' && <div className="mt-1 text-xs text-muted">{dateBr(p.paid_on)} · {p.payment_reference}</div>}</td>
              <td className="px-3 py-2">
                {p.status === 'pending' && canApprove && (
                  <div className="flex flex-col gap-1">
                    <form action={decidePayout}><input type="hidden" name="payout_id" value={p.id} /><input type="hidden" name="back" value={back} /><input type="hidden" name="decision" value="approve" />
                      <button className="h-8 rounded-md bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong">Aprovar</button></form>
                    <form action={decidePayout} className="flex gap-1"><input type="hidden" name="payout_id" value={p.id} /><input type="hidden" name="back" value={back} /><input type="hidden" name="decision" value="cancel" />
                      <input name="note" required minLength={3} placeholder="Motivo" className="field h-8 w-28 text-xs" /><button className="h-8 rounded-md px-2 text-xs text-ink-soft hover:bg-surface-muted">Cancelar</button></form>
                  </div>
                )}
                {p.status === 'approved' && canPay && (
                  <form action={markPaid} className="flex flex-wrap gap-1"><input type="hidden" name="payout_id" value={p.id} /><input type="hidden" name="back" value={back} />
                    <input type="date" name="paid_on" defaultValue={today} max={today} className="field h-8 w-36 text-xs" aria-label="Data do pagamento" />
                    <input name="reference" required minLength={3} placeholder="Comprovante (PIX, TED)" className="field h-8 w-40 text-xs" />
                    <button className="h-8 rounded-md border border-line px-2 text-xs hover:bg-surface-muted">Marcar pago</button></form>
                )}
              </td>
            </tr>
          ))}
          {!rows.length && <tr><td colSpan={names ? 9 : 8} className="px-3 py-6 text-center text-muted">Nenhum repasse.</td></tr>}
        </tbody>
      </table>
    </div>
  )
}
