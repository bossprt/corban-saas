import Link from 'next/link'
import { brlText } from '@/lib/receipts/format'
import { dateBr } from '@/lib/payout/format'
import { batchItemLabel, breakdownItemLabel, type Breakdown } from '@/lib/payout/batches'
import { breakdownView } from '@/lib/payout/breakdown'

// The contracts a payment pays and how its amount is made (owner, 06/11/2026). Same table as the batch screen, ending
// with: Soma dos contratos + outros lançamentos = Total pago; a difference, when there is one, is shown in red.
// No hooks: used by server pages and by "Pagar vendedores" (client).
export function PayoutBreakdown({ b, total, empty }: { b: Breakdown; total: string; empty?: string }) {
  if (b.undone) return <p className="px-4 py-3 text-sm text-muted">Pagamento desfeito ou cancelado: os contratos voltaram para o próximo pagamento.</p>
  const v = breakdownView(b, total)
  return (
    <div>
      {b.contracts.length ? (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted">
              <tr><th className="px-4 py-2">Contrato</th><th className="px-4 py-2">Cliente</th><th className="px-4 py-2">Banco · convênio · produto</th><th className="px-4 py-2 text-right">Liberado</th><th className="px-4 py-2">Pago ao cliente</th><th className="px-4 py-2 text-right">Comissão</th></tr>
            </thead>
            <tbody>
              {b.contracts.map((c, k) => (
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
      ) : <p className="px-4 py-3 text-sm text-muted">{empty ?? 'Nenhum contrato neste pagamento.'}</p>}

      <div className="flex justify-end border-t border-line px-4 py-3">
        <table className="w-full max-w-md text-[13px]">
          <tbody>
            <tr><td className="py-0.5 text-ink-soft">Soma dos contratos ({v.contractCount})</td><td className="num py-0.5 text-right text-ink">{brlText(v.contractsTotal)}</td></tr>
            {b.others.map((o, k) => (
              <tr key={`${o.kind}-${k}`}>
                <td className="py-0.5 text-ink-soft">{String(o.amount).startsWith('-') ? '−' : '+'} {breakdownItemLabel(o)}{o.description ? <span className="text-muted"> · {o.description}</span> : null}{o.effective_on ? <span className="text-muted"> · {dateBr(o.effective_on)}</span> : null}</td>
                <td className={`num py-0.5 text-right ${String(o.amount).startsWith('-') ? 'text-[#991B1B]' : 'text-ink'}`}>{brlText(o.amount)}</td>
              </tr>
            ))}
            {v.hasDifference && (
              <tr><td className="py-0.5 font-semibold text-[#991B1B]">Diferença não explicada</td><td className="num py-0.5 text-right font-semibold text-[#991B1B]">{brlText(v.difference)}</td></tr>
            )}
            <tr className="border-t border-line"><td className="pt-1.5 font-semibold text-ink">Total pago</td><td className="num pt-1.5 text-right text-base font-semibold text-ink">{brlText(v.total)}</td></tr>
          </tbody>
        </table>
      </div>
      {v.hasDifference && <p className="px-4 pb-3 text-xs text-[#991B1B]">A soma dos contratos e lançamentos não bate com o valor pago. Confira o extrato antes de pagar ou avise o suporte.</p>}
    </div>
  )
}
