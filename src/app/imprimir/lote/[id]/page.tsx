import Link from 'next/link'
import { notFound } from 'next/navigation'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import { formatTaxId } from '@/lib/sellers'
import { brlText } from '@/lib/receipts/format'
import type { BatchDetail } from '@/lib/payout/batches'
import { PrintBar } from '../../PrintBar'
import { ContractTable, PRINT_CSS, PartialNote, SheetFooter, SheetHeader, Signatures, TotalInWords, payTo, sumOf } from '../../sheets'

const day = (iso: string) => iso.slice(0, 10).split('-').reverse().join('/')
type Part = 'tudo' | 'resumo' | 'demonstrativos'

// Printed payment batch (owner, 21/10/2026): sheet 1 is the batch summary (one line per person, where to pay, total in
// words, signatures); then one statement per person. "?parte=resumo|demonstrativos" prints only that part;
// "?pessoa=<payment>" prints only that person's statement. Undone payments are left out.
export default async function PrintBatchPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ parte?: string; pessoa?: string }> }) {
  const { id } = await params
  const sp = await searchParams
  if (!isUuid(id)) notFound()
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'repasse.view')) notFound()
  const { data, error } = await supabase.rpc('payout_batch_detail', { p_batch: id })
  if (error || !data) notFound()
  const b = data as BatchDetail
  const paid = b.lines.filter(l => l.status === 'paid')
  const only = sp.pessoa && isUuid(sp.pessoa) ? paid.filter(l => l.payout_id === sp.pessoa) : null
  const part: Part = only ? 'demonstrativos' : sp.parte === 'resumo' || sp.parte === 'demonstrativos' ? sp.parte : 'tudo'
  const people = only ?? paid
  // Only what was really paid (an undone payment of the batch is left out).
  const total = sumOf(paid.map(l => l.amount))
  const sheets = (part === 'tudo' ? 1 : 0) + (part === 'resumo' ? 1 : people.length)
  const contractsOf = (l: BatchDetail['lines'][number]) => l.contracts.filter(c => c.proposal_id).length
  const link = (p: Part) => `/imprimir/lote/${id}?parte=${p}`

  return (
    <div className="sheets">
      <style>{PRINT_CSS}</style>
      <PrintBar back={`/app/repasse/lotes/${id}`}>
        {!only && (['tudo', 'resumo', 'demonstrativos'] as Part[]).map(p => (
          <Link key={p} href={link(p)} className={`inline-flex h-9 items-center rounded-[10px] border px-3 text-sm ${p === part ? 'border-brand bg-brand/10 font-semibold text-brand' : 'border-line bg-surface hover:bg-surface-muted'}`}>
            {p === 'tudo' ? 'Lote completo' : p === 'resumo' ? 'Só o resumo' : 'Só os demonstrativos'}
          </Link>
        ))}
        {/* One seller of the batch (owner, 21/10/2026). */}
        <form method="get" className="flex items-center gap-1.5 text-sm">
          <label className="flex items-center gap-1.5">Vendedor
            <select name="pessoa" defaultValue={only?.[0]?.payout_id ?? ''} className="h-9 rounded-[10px] border border-line bg-surface px-2.5 text-sm text-ink w-56">
              <option value="">Todos</option>
              {paid.map(l => <option key={l.payout_id} value={l.payout_id}>{l.holder}</option>)}
            </select>
          </label>
          <button className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 hover:bg-surface-muted">Ver</button>
        </form>
      </PrintBar>

      {(part === 'tudo' || part === 'resumo') && (
        <section className="sheet">
          <SheetHeader company={b.company} title="Lote de pagamento de comissões" subtitle={`Resumo · folha 1 de ${sheets}`} />
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: 8, marginBottom: 12 }}>
            <div className="box"><div className="muted">Data do pagamento</div><strong>{day(b.paid_on)}</strong></div>
            <div className="box"><div className="muted">Conta pagadora</div><strong>{b.bank_accounts ?? '—'}</strong></div>
            <div className="box"><div className="muted">Pessoas · contratos</div><strong>{paid.length} · {paid.reduce((s, l) => s + contractsOf(l), 0)}</strong></div>
            <div className="box"><div className="muted">Total do lote</div><strong>{brlText(total)}</strong></div>
          </div>
          <table style={{ tableLayout: 'fixed' }}>
            <thead><tr><th style={{ width: '30%' }}>Beneficiário</th><th style={{ width: '18%' }}>CPF/CNPJ</th><th style={{ width: '30%' }}>Pagar em (PIX / conta)</th><th className="c" style={{ width: '9%' }}>Contratos</th><th className="r" style={{ width: '13%' }}>Valor pago</th></tr></thead>
            <tbody>
              {paid.map(l => (
                <tr key={l.payout_id}>
                  <td>{l.holder}</td>
                  <td>{l.holder_document ? formatTaxId(l.holder_document) : '—'}</td>
                  <td style={{ color: l.pay_target ? undefined : '#a14b00' }}>{payTo(l.pay_target)}</td>
                  <td className="c">{contractsOf(l)}</td>
                  <td className="r">{brlText(l.amount)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={3} style={{ fontWeight: 700, borderBottom: 0 }}>Total do lote</td><td className="c" style={{ fontWeight: 700, borderBottom: 0 }}>{paid.reduce((s, l) => s + contractsOf(l), 0)}</td><td className="r" style={{ fontWeight: 700, fontSize: 12, borderBottom: 0 }}>{brlText(total)}</td></tr></tfoot>
          </table>
          <TotalInWords label="Total do lote" amount={total} />
          {b.payment_reference && <p className="muted" style={{ marginTop: 6 }}>Comprovante: {b.payment_reference} · registrado por {b.paid_by ?? '—'}</p>}
          <Signatures left="Preparado por · financeiro" right="Aprovado por · diretoria" />
          <SheetFooter right={part === 'tudo' ? `Folhas 2 a ${sheets}: demonstrativo de cada beneficiário` : undefined} />
        </section>
      )}

      {(part === 'tudo' || part === 'demonstrativos') && people.map((l, i) => (
        <section key={l.payout_id} className="sheet">
          <SheetHeader company={b.company} title="Demonstrativo de pagamento de comissão" subtitle={`Lote de ${day(b.paid_on)} · ${i + 1} de ${people.length}`} />
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div className="box">
              <div className="muted">Beneficiário</div>
              <strong>{l.holder}</strong>
              <div>{l.holder_document ? `CPF/CNPJ ${formatTaxId(l.holder_document)}` : 'CPF/CNPJ não cadastrado'}</div>
              <div>{payTo(l.pay_target)}</div>
            </div>
            <div className="box">
              <div className="muted">Pagamento</div>
              <div><span className="muted">Data:</span> {day(b.paid_on)}</div>
              <div><span className="muted">Conta pagadora:</span> {b.bank_accounts ?? '—'}</div>
              <div><span className="muted">Comprovante:</span> {b.payment_reference ?? '—'}</div>
            </div>
          </div>
          <ContractTable contracts={l.contracts} total={l.amount} />
          <PartialNote contracts={l.contracts} />
          <TotalInWords label="Total pago" amount={l.amount} />
          <Signatures left={b.company?.name ?? 'Empresa'} right={`${l.holder} · beneficiário`} />
          <SheetFooter right={`${i + 1} de ${people.length}`} />
        </section>
      ))}
      {people.length === 0 && part !== 'resumo' && <p className="print-hide text-center text-sm text-muted">Nenhum pagamento pago neste lote.</p>}
    </div>
  )
}
