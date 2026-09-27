import { Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brl, DRE_ORDER, monthLabel } from '@/lib/finance/labels'
import { FinanceTabs } from '../FinanceTabs'

type Flow = { month: string; realized_in: string; realized_out: string; forecast_in: string; forecast_out: string }
type Dre = { month: string; kind: string; account_code: string; account_name: string; total: string }
const cents = (v: string | number) => Math.round(Number(v) * 100)
const money = (c: number) => brl(c / 100)

// Cash flow (realized by settlement date, forecast by due date) and income statement (by competence), by branch.
export default async function FinanceReportsPage({ searchParams }: { searchParams: Promise<{ ano?: string; filial?: string }> }) {
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Fluxo de caixa e DRE" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const sp = await searchParams
  const year = /^\d{4}$/.test(sp.ano ?? '') ? Number(sp.ano) : new Date().getFullYear()
  const branch = /^[0-9a-f-]{36}$/.test(sp.filial ?? '') ? sp.filial! : null
  const from = `${year}-01-01`, to = `${year}-12-31`
  const [{ data: flow }, { data: dre }, { data: branches }] = await Promise.all([
    supabase.rpc('fin_cash_flow', { p_org: organization.id, p_from: from, p_to: to, p_branch: branch }),
    supabase.rpc('fin_income_statement', { p_org: organization.id, p_from: from, p_to: to, p_branch: branch }),
    supabase.from('organization_branches').select('id,name').eq('is_active', true).order('name'),
  ])
  const months = ((flow ?? []) as Flow[]).map(f => f.month)
  const lines = (dre ?? []) as Dre[]
  // DRE: per kind and month (in cents), plus the accounts under each kind.
  const byKind = new Map<string, Map<string, number>>()
  const accounts = new Map<string, { code: string; name: string; kind: string; months: Map<string, number> }>()
  for (const l of lines) {
    const m = l.month.slice(0, 10)
    const k = byKind.get(l.kind) ?? new Map<string, number>(); k.set(m, (k.get(m) ?? 0) + cents(l.total)); byKind.set(l.kind, k)
    const a = accounts.get(l.account_code) ?? { code: l.account_code, name: l.account_name, kind: l.kind, months: new Map<string, number>() }
    a.months.set(m, (a.months.get(m) ?? 0) + cents(l.total)); accounts.set(l.account_code, a)
  }
  const kindAt = (k: string, m: string) => byKind.get(k)?.get(m) ?? 0
  const running = new Map<string, number>()
  // Realized balance accumulated month by month (computed before rendering).
  const flowRows = ((flow ?? []) as Flow[]).reduce<{ f: Flow; net: number; acc: number }[]>((out, f) => {
    const net = cents(f.realized_in) - cents(f.realized_out)
    return [...out, { f, net, acc: (out.at(-1)?.acc ?? 0) + net }]
  }, [])

  return (
    <section>
      <PageHeader title="Fluxo de caixa e DRE" description="Fluxo de caixa: realizado pela data da baixa, previsto pelo vencimento. DRE: pela competência, sem transferências entre contas." />
      <FinanceTabs current="/app/financeiro/empresa/relatorios" />
      <form className="mb-4 flex flex-wrap items-end gap-2" action="/app/financeiro/empresa/relatorios">
        <input name="ano" type="number" min={2020} max={2100} defaultValue={year} aria-label="Ano" className="field h-9 w-28 py-1" />
        <select name="filial" defaultValue={branch ?? ''} aria-label="Filial" className="field h-9 w-auto py-1"><option value="">Todas as filiais</option>{(branches ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
        <button className="h-9 rounded-[10px] border border-line px-3 text-sm hover:bg-surface-muted">Ver</button>
      </form>

      <Card className="mb-4 overflow-hidden">
        <CardHeader title={`Fluxo de caixa ${year}`} />
        <div className="overflow-x-auto">
          <table className="w-full text-right text-sm">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="px-3 py-2 text-left">Mês</th><th className="px-3 py-2">Entrou</th><th className="px-3 py-2">Saiu</th><th className="px-3 py-2">Saldo do mês</th><th className="px-3 py-2">A receber</th><th className="px-3 py-2">A pagar</th><th className="px-3 py-2">Acumulado realizado</th></tr></thead>
            <tbody>
              {flowRows.map(({ f, net, acc: balance }) => {
                return (
                  <tr key={f.month} className="border-t border-line">
                    <td className="px-3 py-1.5 text-left capitalize">{monthLabel(f.month)}</td>
                    <td className="num px-3 py-1.5 text-[#15803D]">{money(cents(f.realized_in))}</td>
                    <td className="num px-3 py-1.5">{money(cents(f.realized_out))}</td>
                    <td className={`num px-3 py-1.5 font-medium ${net < 0 ? 'text-[#B91C1C]' : 'text-ink'}`}>{money(net)}</td>
                    <td className="num px-3 py-1.5 text-muted">{money(cents(f.forecast_in))}</td>
                    <td className="num px-3 py-1.5 text-muted">{money(cents(f.forecast_out))}</td>
                    <td className={`num px-3 py-1.5 ${balance < 0 ? 'text-[#B91C1C]' : 'text-ink'}`}>{money(balance)}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </Card>

      <Card className="overflow-hidden">
        <CardHeader title={`DRE ${year}`} />
        <div className="overflow-x-auto">
          <table className="w-full text-right text-[13px]">
            <thead className="bg-surface-muted text-xs text-muted"><tr><th className="sticky left-0 bg-surface-muted px-3 py-2 text-left">Linha</th>{months.map(m => <th key={m} className="px-3 py-2 capitalize">{monthLabel(m)}</th>)}<th className="px-3 py-2">Ano</th></tr></thead>
            <tbody>
              {DRE_ORDER.map(row => {
                const accs = [...accounts.values()].filter(a => a.kind === row.kind).sort((a, b) => a.code.localeCompare(b.code, 'pt-BR', { numeric: true }))
                for (const m of months) running.set(m, (running.get(m) ?? 0) + kindAt(row.kind, m))
                const year = months.reduce((s, m) => s + kindAt(row.kind, m), 0)
                const subtotalYear = months.reduce((s, m) => s + (running.get(m) ?? 0), 0)
                return [
                  <tr key={row.kind} className="border-t border-line font-medium">
                    <td className="sticky left-0 bg-surface px-3 py-1.5 text-left">{row.label}</td>
                    {months.map(m => <td key={m} className="num px-3 py-1.5">{money(kindAt(row.kind, m))}</td>)}
                    <td className="num px-3 py-1.5">{money(year)}</td>
                  </tr>,
                  ...accs.map(a => (
                    <tr key={`${row.kind}-${a.code}`} className="text-muted">
                      <td className="sticky left-0 bg-surface px-3 py-1 pl-7 text-left">{a.code} {a.name}</td>
                      {months.map(m => <td key={m} className="num px-3 py-1">{a.months.get(m) ? money(a.months.get(m)!) : ''}</td>)}
                      <td className="num px-3 py-1">{money(months.reduce((s, m) => s + (a.months.get(m) ?? 0), 0))}</td>
                    </tr>
                  )),
                  row.subtotal ? (
                    <tr key={`${row.kind}-sub`} className="border-t border-line-strong bg-surface-muted font-semibold text-ink">
                      <td className="sticky left-0 bg-surface-muted px-3 py-1.5 text-left">= {row.subtotal}</td>
                      {months.map(m => <td key={m} className={`num px-3 py-1.5 ${(running.get(m) ?? 0) < 0 ? 'text-[#B91C1C]' : ''}`}>{money(running.get(m) ?? 0)}</td>)}
                      <td className={`num px-3 py-1.5 ${subtotalYear < 0 ? 'text-[#B91C1C]' : ''}`}>{money(subtotalYear)}</td>
                    </tr>
                  ) : null,
                ]
              })}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
