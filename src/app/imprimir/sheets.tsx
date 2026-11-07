import { brlText } from '@/lib/receipts/format'
import { moneyInWords } from '@/lib/money-words'
import { add, fromDecimalString, toDecimalString } from '@/lib/commission/money'
import { batchItemLabel, breakdownItemLabel, type BatchContract, type Breakdown, type Company } from '@/lib/payout/batches'
import { breakdownView, type BatchFooter } from '@/lib/payout/breakdown'
import { formatTaxId, payToText, type PayTarget } from '@/lib/sellers'

// Printed payout documents (owner, 21/10/2026): A4 landscape sheets, black on white, one per page. Shared by the batch print and
// the per-person report. Money arrives as decimal text and is added as exact decimals.

export const PRINT_CSS = `
@page { size: A4 landscape; margin: 10mm; }
.sheets { background: #e9e7e2; padding: 16px 8px 32px; min-height: 100vh; }
.sheet { background: #fff; color: #111; width: 297mm; max-width: 100%; min-height: 190mm; margin: 0 auto 16px; padding: 10mm 12mm 9mm;
  box-sizing: border-box; font-size: 11px; line-height: 1.45; display: flex; flex-direction: column; box-shadow: 0 1px 4px rgba(0,0,0,.12); }
.sheet table { width: 100%; border-collapse: collapse; }
.sheet th { text-align: left; font-weight: 600; background: #f2f1ee; border-bottom: 1px solid #999; padding: 5px 6px; }
.sheet td { border-bottom: 1px solid #ddd; padding: 5px 6px; vertical-align: top; }
.sheet .r { text-align: right; } .sheet .c { text-align: center; } .sheet .muted { color: #555; }
.sheet .box { border: 1px solid #bbb; border-radius: 3px; padding: 6px 9px; }
@media print {
  body { background: #fff !important; }
  .print-hide { display: none !important; }
  .sheets { background: #fff; padding: 0; }
  .sheet { box-shadow: none; margin: 0; width: auto; min-height: 0; padding: 0; page-break-after: always; break-after: page; }
  .sheet:last-child { page-break-after: auto; break-after: auto; }
}`

const day = (iso: string | null | undefined) => (iso ? iso.slice(0, 10).split('-').reverse().join('/') : '—')
const money = (v: string | null | undefined) => (v ? brlText(v).replace('R$ ', '').replace('R$ ', '') : '—')
export const sumOf = (values: (string | null | undefined)[]) => toDecimalString(values.reduce((s, v) => add(s, fromDecimalString(String(v ?? '0'))), fromDecimalString('0')), 2)
export const issuedAt = () => new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })

export function SheetHeader({ company, title, subtitle }: { company: Company | undefined; title: string; subtitle: string }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', borderBottom: '2px solid #111', paddingBottom: 8, marginBottom: 12 }}>
      <div>
        <div style={{ fontSize: 15, fontWeight: 700 }}>{company?.name ?? ''}</div>
        {company?.document && <div className="muted">CNPJ {formatTaxId(company.document)}</div>}
      </div>
      <div style={{ textAlign: 'right' }}>
        <div style={{ fontSize: 14, fontWeight: 700 }}>{title}</div>
        <div className="muted">{subtitle}</div>
      </div>
    </div>
  )
}

export function SheetFooter({ left, right }: { left?: string; right?: string }) {
  return (
    <div className="muted" style={{ marginTop: 'auto', paddingTop: 14, fontSize: 10, display: 'flex', justifyContent: 'space-between' }}>
      <span>{left ?? `Emitido em ${issuedAt()} pelo Corban`}</span><span>{right}</span>
    </div>
  )
}

export function Signatures({ left, right }: { left: string; right: string }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 40, marginTop: 34 }}>
      <div style={{ borderTop: '1px solid #555', paddingTop: 4, textAlign: 'center' }} className="muted">{left}</div>
      <div style={{ borderTop: '1px solid #555', paddingTop: 4, textAlign: 'center' }} className="muted">{right}</div>
    </div>
  )
}

export function TotalInWords({ label, amount }: { label: string; amount: string }) {
  return (
    <div style={{ marginTop: 10, padding: '7px 9px', background: '#f2f1ee', borderRadius: 3 }}>
      <strong>{label}: R$ {money(amount)}</strong> <span className="muted">({moneyInWords(amount)})</span>
    </div>
  )
}

export const payTo = (t: PayTarget | null | undefined) => (t ? payToText(t) : 'Sem conta cadastrada')

// The contracts a payment paid, as a table; the footer splits the amount (owner, 06/11/2026): Soma dos contratos, each
// other entry (vale, bônus, desconto, saldo anterior, desconto do negativo) and Total pago. A difference is printed, never hidden.
export function ContractTable({ b, total }: { b: Pick<Breakdown, 'contracts' | 'others'>; total: string }) {
  const contracts = b.contracts ?? []
  const others = b.others ?? []
  const released = sumOf(contracts.map(c => c.released ?? null))
  const v = breakdownView(b, total)
  const foot = { borderBottom: 0, paddingTop: 2, paddingBottom: 2 }
  return (
    <table style={{ tableLayout: 'fixed' }}>
      <thead>
        <tr>
          <th style={{ width: '11%' }}>Contrato</th><th style={{ width: '27%' }}>Cliente</th><th style={{ width: '25%' }}>Banco · convênio · produto</th>
          <th className="r" style={{ width: '13%' }}>Liberado</th><th className="c" style={{ width: '11%' }}>Pago cliente</th><th className="r" style={{ width: '13%' }}>Comissão</th>
        </tr>
      </thead>
      <tbody>
        {contracts.length === 0 && <tr><td colSpan={6} className="muted">Pagamento sem contratos.</td></tr>}
        {contracts.map((c, i) => (
          <tr key={`${c.proposal_id ?? c.kind}-${i}`}>
            <td>{batchItemLabel(c)}</td>
            <td>{c.client ?? ''}</td>
            <td>{[c.bank, c.agreement, c.product].filter(Boolean).join(' · ')}</td>
            <td className="r">{money(c.released)}</td>
            <td className="c">{c.proposal_id ? day(c.paid_to_client_on) : ''}</td>
            <td className="r">{money(c.amount)}{c.partial ? ' *' : ''}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <td colSpan={3} style={{ ...foot, fontWeight: 700, paddingTop: 5 }}>Soma dos contratos ({v.contractCount})</td>
          <td className="r" style={{ ...foot, fontWeight: 700, paddingTop: 5 }}>{money(released)}</td><td style={foot} />
          <td className="r" style={{ ...foot, fontWeight: 700, paddingTop: 5 }}>{money(v.contractsTotal)}</td>
        </tr>
        {others.map((o, i) => (
          <tr key={`${o.kind}-${i}`}>
            <td colSpan={5} style={foot}>{i === 0 ? 'Outros lançamentos: ' : ''}{breakdownItemLabel(o)}{o.description ? ` · ${o.description}` : ''}{o.effective_on ? ` · ${day(o.effective_on)}` : ''}</td>
            <td className="r" style={foot}>{money(o.amount)}</td>
          </tr>
        ))}
        {v.hasDifference && (
          <tr><td colSpan={5} style={{ ...foot, fontWeight: 700 }}>Diferença não explicada</td><td className="r" style={{ ...foot, fontWeight: 700 }}>{money(v.difference)}</td></tr>
        )}
        <tr>
          <td colSpan={5} style={{ fontWeight: 700, borderBottom: 0, borderTop: '1px solid #999' }}>Total pago</td>
          <td className="r" style={{ fontWeight: 700, fontSize: 12, borderBottom: 0, borderTop: '1px solid #999' }}>R$ {money(total)}</td>
        </tr>
      </tfoot>
    </table>
  )
}

// Footer of several payments (batch summary, period): Soma dos contratos, Outros lançamentos listed, Total pago.
export function FooterSplit({ f, withHolder }: { f: BatchFooter; withHolder?: boolean }) {
  return (
    <table style={{ marginTop: 8, width: '60%', marginLeft: 'auto' }}>
      <tbody>
        <tr><td style={{ fontWeight: 700 }}>Soma dos contratos</td><td className="r" style={{ fontWeight: 700 }}>{money(f.contractsTotal)}</td></tr>
        {f.others.length > 0 && <tr><td colSpan={2} className="muted" style={{ borderBottom: 0, paddingBottom: 0 }}>Outros lançamentos</td></tr>}
        {f.others.map((o, i) => (
          <tr key={i}><td>{withHolder ? `${o.holder} · ` : ''}{o.label}{o.description ? ` · ${o.description}` : ''}</td><td className="r">{money(o.amount)}</td></tr>
        ))}
        {f.others.length > 0 && <tr><td className="muted">Total de outros lançamentos</td><td className="r">{money(f.othersTotal)}</td></tr>}
        {f.hasDifference && <tr><td style={{ fontWeight: 700 }}>Diferença não explicada</td><td className="r" style={{ fontWeight: 700 }}>{money(f.difference)}</td></tr>}
        <tr><td style={{ fontWeight: 700, borderBottom: 0 }}>Total pago</td><td className="r" style={{ fontWeight: 700, fontSize: 12, borderBottom: 0 }}>R$ {money(f.paidTotal)}</td></tr>
      </tbody>
    </table>
  )
}

export function PartialNote({ contracts }: { contracts: BatchContract[] }) {
  return contracts.some(c => c.partial) ? <p className="muted" style={{ marginTop: 6 }}>* Pago em parte neste pagamento; o restante vem no próximo.</p> : null
}
