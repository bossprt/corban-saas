import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ChevronLeft, Download } from 'lucide-react'
import { Card, Kpi, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, dayLabel, FIN_SOURCE_LABEL } from '@/lib/finance/labels'
import { loadMovements } from '@/lib/finance/movements'
import { isUuid } from '@/lib/team'
import { FinanceTabs } from '../../FinanceTabs'

// Movements of one company bank account (owner request 07/10/2026): what came in and left in the period, with the
// running balance, to check against the bank statement. Read only.
export default async function BankMovementsPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ de?: string; ate?: string }> }) {
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Movimentações" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const { id } = await params
  if (!isUuid(id)) notFound()
  const sp = await searchParams
  const m = await loadMovements(supabase, id, sp.de, sp.ate)
  if (!m) notFound()
  const query = `de=${m.from}&ate=${m.to}`

  return (
    <section>
      <Link href="/app/financeiro/empresa/contas" className="mb-2 inline-flex items-center gap-1 text-sm text-muted hover:text-ink"><ChevronLeft size={16} aria-hidden />Contas bancárias</Link>
      <PageHeader title={`Movimentações · ${m.bank.label}`} description={`${m.bank.bank_name}. Tudo o que foi pago ou recebido nesta conta no período, com o saldo dia a dia. Saldo inicial ${brl(m.bank.opening_balance)} em ${dayLabel(m.bank.opening_on)}.`} />
      <FinanceTabs current="/app/financeiro/empresa/contas" />

      <form className="mb-4 flex flex-wrap items-end gap-2">
        <label className="text-[13px] font-medium text-ink-soft">De<input type="date" name="de" defaultValue={m.from} min={m.bank.opening_on} className="field mt-1.5 block h-9 w-auto py-1" /></label>
        <label className="text-[13px] font-medium text-ink-soft">Até<input type="date" name="ate" defaultValue={m.to} className="field mt-1.5 block h-9 w-auto py-1" /></label>
        <button className="inline-flex h-9 items-center rounded-[10px] bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong">Filtrar</button>
        <a href={`/api/financeiro/contas/${id}/movimentos?${query}`} download className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted"><Download size={15} aria-hidden />Baixar Excel</a>
      </form>

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Kpi label={`Saldo em ${dayLabel(m.from)} (início do dia)`} value={brl(m.startBalance)} />
        <Kpi label="Entradas" value={brl(m.totalIn)} />
        <Kpi label="Saídas" value={brl(m.totalOut)} />
        <Kpi label={`Saldo em ${dayLabel(m.to)}`} value={brl(m.endBalance)} />
      </div>

      <Card className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-surface-muted text-left text-xs text-muted">
              <tr>
                <th className="px-4 py-2 font-medium">Data</th><th className="px-3 py-2 font-medium">Descrição</th><th className="px-3 py-2 font-medium">Origem</th>
                <th className="px-3 py-2 text-right font-medium">Entrada</th><th className="px-3 py-2 text-right font-medium">Saída</th><th className="px-4 py-2 text-right font-medium">Saldo</th>
              </tr>
            </thead>
            <tbody>
              {m.rows.map(r => (
                <tr key={r.id} className="border-t border-line">
                  <td className="num whitespace-nowrap px-4 py-2">{dayLabel(r.settled_on)}</td>
                  <td className="px-3 py-2"><span className="block text-ink">{r.description}</span>{r.counterpart && <span className="block text-xs text-muted">{r.counterpart}</span>}</td>
                  <td className="px-3 py-2 text-xs text-muted">{FIN_SOURCE_LABEL[r.source] ?? r.source}</td>
                  <td className="num whitespace-nowrap px-3 py-2 text-right text-[#1D6E4F]">{r.amountIn ? brl(r.amountIn) : ''}</td>
                  <td className="num whitespace-nowrap px-3 py-2 text-right text-[#991B1B]">{r.amountOut ? brl(r.amountOut) : ''}</td>
                  <td className="num whitespace-nowrap px-4 py-2 text-right font-medium text-ink">{brl(r.balance)}</td>
                </tr>
              ))}
              {!m.rows.length && <tr><td colSpan={6} className="px-4 py-8 text-center text-muted">Nada pago ou recebido nesta conta no período.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
      {m.beforeOpening > 0 && <p className="mt-3 text-xs text-muted">{m.beforeOpening} movimento(s) desta conta são de antes de {dayLabel(m.bank.opening_on)}: já estão dentro do saldo inicial e não aparecem aqui.</p>}
    </section>
  )
}
