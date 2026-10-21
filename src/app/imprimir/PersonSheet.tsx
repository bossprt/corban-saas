import { formatTaxId } from '@/lib/sellers'
import { brlText } from '@/lib/receipts/format'
import type { AccountReport } from '@/lib/payout/batches'
import { ContractTable, PartialNote, SheetFooter, SheetHeader, Signatures, TotalInWords, payTo } from './sheets'

const day = (iso: string) => iso.slice(0, 10).split('-').reverse().join('/')

// One person's commissions paid over a period, as one printed sheet (used alone and in "todos os vendedores").
export function PersonSheet({ r, page }: { r: AccountReport; page?: string }) {
  const contracts = r.payments.flatMap(p => p.contracts)
  return (
    <section className="sheet">
      <SheetHeader company={r.company} title="Relatório de comissões pagas" subtitle={`Período de ${day(r.from)} a ${day(r.to)}`} />
      <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 10, marginBottom: 12 }}>
        <div className="box">
          <div className="muted">Beneficiário</div>
          <strong>{r.holder.name}</strong>
          <div>{r.holder.document ? `CPF/CNPJ ${formatTaxId(r.holder.document)}` : 'CPF/CNPJ não cadastrado'}</div>
          <div>{payTo(r.holder.pay_target)}</div>
        </div>
        <div className="box">
          <div className="muted">No período</div>
          <div><span className="muted">Pagamentos:</span> {r.payments.length}</div>
          <div><span className="muted">Contratos:</span> {contracts.filter(c => c.proposal_id).length}</div>
          <div><span className="muted">Total pago:</span> <strong>{brlText(r.total)}</strong></div>
        </div>
      </div>

      {r.payments.length === 0 && <p className="muted">Nenhum pagamento no período.</p>}
      {r.payments.map(p => (
        <div key={p.payout_id} style={{ marginBottom: 14, breakInside: 'avoid' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, margin: '4px 0' }}>
            <span>Pagamento de {day(p.paid_on)}{p.reference ? ` · ${p.reference}` : ''}</span><span>{brlText(p.amount)}</span>
          </div>
          <ContractTable contracts={p.contracts} total={p.amount} />
          <PartialNote contracts={p.contracts} />
        </div>
      ))}
      <TotalInWords label="Total pago no período" amount={r.total} />
      <Signatures left={r.company?.name ?? 'Empresa'} right={`${r.holder.name} · beneficiário`} />
      <SheetFooter right={page} />
    </section>
  )
}
