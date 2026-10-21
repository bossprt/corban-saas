import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { formatTaxId } from '@/lib/sellers'
import { brlText } from '@/lib/receipts/format'
import type { AccountReport } from '@/lib/payout/batches'
import { PrintBar } from '../../PrintBar'
import { ContractTable, PRINT_CSS, PartialNote, SheetFooter, SheetHeader, Signatures, TotalInWords, payTo } from '../../sheets'

const DATE = /^\d{4}-\d{2}-\d{2}$/
const day = (iso: string) => iso.slice(0, 10).split('-').reverse().join('/')
const monthStart = () => { const d = new Date(Date.now() - 3 * 3600_000).toISOString(); return `${d.slice(0, 8)}01` }
const today = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10)

// Report per person over a period (owner, 21/10/2026): every payment made to them, contract by contract, with the total.
// Finance, or the person themself (their own report).
export default async function PrintPersonReport({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ de?: string; ate?: string }> }) {
  const { id } = await params
  const sp = await searchParams
  if (!isUuid(id)) notFound()
  const from = DATE.test(sp.de ?? '') ? sp.de! : monthStart()
  const to = DATE.test(sp.ate ?? '') ? sp.ate! : today()
  const { supabase } = await requireAppContext()
  const { data, error } = await supabase.rpc('payout_account_report', { p_account: id, p_from: from, p_to: to })
  if (error || !data) notFound()
  const r = data as AccountReport
  const contracts = r.payments.flatMap(p => p.contracts)

  return (
    <div className="sheets">
      <style>{PRINT_CSS}</style>
      <PrintBar back={`/app/repasse/${id}`}>
        <form className="flex flex-wrap items-center gap-2 text-sm">
          <label className="flex items-center gap-1.5">De<input type="date" name="de" defaultValue={from} className="field h-9" /></label>
          <label className="flex items-center gap-1.5">até<input type="date" name="ate" defaultValue={to} className="field h-9" /></label>
          <button className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 hover:bg-surface-muted">Ver período</button>
        </form>
      </PrintBar>

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
        <SheetFooter />
      </section>
    </div>
  )
}
