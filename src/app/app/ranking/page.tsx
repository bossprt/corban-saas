import Link from 'next/link'
import { redirect } from 'next/navigation'
import { Maximize2, Minimize2, Trophy } from 'lucide-react'
import { Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { cmp, div, fromDecimalString, mul, toDecimalString } from '@/lib/commission/money'
import { isPortalUser } from '@/lib/portal'
import { brlText } from '@/lib/receipts/format'
import { PERIODS, periodRange, type PeriodKey } from '../OwnerDashboard'
import { AutoRefresh } from './AutoRefresh'

type Seller = { seller_id: string; name: string; paid_count: number; paid_amount: string; typed_count: number; typed_amount: string; goal: string | null }
type Ranking = {
  sellers: Seller[]
  totals: { paid_count: number; paid_amount: string; typed_count: number; typed_amount: string; no_seller_paid: number; goal: string }
  funnel: { leads: number; typed: number; paid: number }
  last_paid: { name: string; amount: string; paid_on: string }[]
}
const METRICS = { paga: 'Produção paga', digitada: 'Produção digitada' } as const
type Metric = keyof typeof METRICS

const R = (v: string | number | null | undefined) => fromDecimalString(String(v ?? 0))
const pct = (part: string, whole: string) => (cmp(R(whole), R(0)) > 0 ? Math.min(100, Math.round(Number(toDecimalString(mul(div(R(part), R(whole)), R(100)), 0)))) : 0)
const day = (iso: string) => iso.split('-').reverse().slice(0, 2).join('/')
const MEDAL = ['bg-[#F5C542] text-[#5C4400]', 'bg-[#C9CED6] text-[#2F3640]', 'bg-[#D79A62] text-[#4A2A0E]']

// Ranking and sales board (owner, 20/10/2026): the whole internal team sees who sold what in the period. Only production
// (released amount and count); commission and payout of anyone never show here. "?tv=1" fills the screen and refreshes.
export default async function RankingPage({ searchParams }: { searchParams: Promise<{ periodo?: string; metrica?: string; tv?: string }> }) {
  const ctx = await requireAppContext()
  if (isPortalUser(ctx.access?.roleKey, ctx.modules)) redirect('/app/portal')
  if (!(can(ctx.access, 'leads.view') || can(ctx.access, 'relatorios.view') || can(ctx.access, 'financeiro.view'))) redirect('/app/hoje')
  const sp = await searchParams
  const period: PeriodKey = sp.periodo && sp.periodo in PERIODS ? sp.periodo as PeriodKey : 'mes'
  const metric: Metric = sp.metrica === 'digitada' ? 'digitada' : 'paga'
  const tv = sp.tv === '1'
  const range = periodRange(period)
  const { data, error } = await ctx.supabase.rpc('sales_ranking', { p_org: ctx.organization.id, p_from: range.from, p_to: range.to })
  const board = data as Ranking | null
  const href = (over: Record<string, string>) => `/app/ranking?${new URLSearchParams({ periodo: period, metrica: metric, ...(tv ? { tv: '1' } : {}), ...over })}`

  if (error || !board) return <section><PageHeader title="Ranking de vendas" /><Card className="p-5 text-sm text-ink-soft">Não foi possível carregar o ranking agora.</Card></section>

  const amountOf = (s: Seller) => (metric === 'paga' ? s.paid_amount : s.typed_amount)
  const countOf = (s: Seller) => (metric === 'paga' ? s.paid_count : s.typed_count)
  const rows = [...board.sellers].filter(s => countOf(s) > 0 || s.goal).sort((a, b) => cmp(R(amountOf(b)), R(amountOf(a))) || countOf(b) - countOf(a) || a.name.localeCompare(b.name))
  const top = rows.filter(s => countOf(s) > 0).slice(0, 3)
  const total = metric === 'paga' ? board.totals.paid_amount : board.totals.typed_amount
  const totalCount = metric === 'paga' ? board.totals.paid_count : board.totals.typed_count
  const teamGoal = board.totals.goal
  const goalPct = pct(board.totals.paid_amount, teamGoal)
  const funnel = board.funnel

  const pill = (active: boolean) => `rounded-lg px-3 py-1.5 text-sm ${active ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`
  const big = tv ? 'text-3xl' : 'text-2xl'

  const content = (
    <>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        <nav aria-label="Período" className="flex gap-1 rounded-[12px] border border-line bg-surface p-1">
          {(Object.keys(PERIODS) as PeriodKey[]).map(k => <Link key={k} href={href({ periodo: k })} aria-current={k === period ? 'page' : undefined} className={pill(k === period)}>{PERIODS[k]}</Link>)}
        </nav>
        <nav aria-label="Métrica" className="flex gap-1 rounded-[12px] border border-line bg-surface p-1">
          {(Object.keys(METRICS) as Metric[]).map(k => <Link key={k} href={href({ metrica: k })} aria-current={k === metric ? 'page' : undefined} className={pill(k === metric)}>{METRICS[k]}</Link>)}
        </nav>
        <Link href={tv ? `/app/ranking?${new URLSearchParams({ periodo: period, metrica: metric })}` : href({ tv: '1' })} className="ml-auto inline-flex items-center gap-1.5 rounded-[10px] border border-line bg-surface px-3 py-1.5 text-sm text-ink-soft hover:bg-surface-muted">
          {tv ? <><Minimize2 size={14} aria-hidden />Sair do modo TV</> : <><Maximize2 size={14} aria-hidden />Modo TV</>}
        </Link>
      </div>

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Card className="px-4 py-3"><span className="block text-xs text-muted">{METRICS[metric]} · {PERIODS[period].toLowerCase()}</span><span className={`num ${big} font-semibold text-ink`}>{brlText(total)}</span></Card>
        <Card className="px-4 py-3"><span className="block text-xs text-muted">Contratos</span><span className={`num ${big} font-semibold text-ink`}>{totalCount}</span></Card>
        <Card className="px-4 py-3"><span className="block text-xs text-muted">Ticket médio</span><span className={`num ${big} font-semibold text-ink`}>{totalCount ? brlText(toDecimalString(div(R(total), R(totalCount)), 2)) : '—'}</span></Card>
        <Card className="px-4 py-3">
          <span className="block text-xs text-muted">Meta da equipe (pago no mês)</span>
          {cmp(R(teamGoal), R(0)) > 0 ? (
            <>
              <span className={`num ${big} font-semibold text-ink`}>{goalPct}%</span>
              <span className="mt-1 block h-2 overflow-hidden rounded-full bg-[#F3F1EC]"><span className="block h-2 rounded-full bg-brand" style={{ width: `${goalPct}%` }} /></span>
              <span className="num mt-1 block text-xs text-muted">{brlText(board.totals.paid_amount)} de {brlText(teamGoal)}</span>
            </>
          ) : <span className="mt-1 block text-sm text-muted">Sem meta cadastrada. <Link href="/app/metas" className="text-brand hover:underline">Cadastrar</Link></span>}
        </Card>
      </div>

      {top.length > 0 && (
        <div className="mb-4 grid gap-3 sm:grid-cols-3">
          {top.map((s, i) => (
            <Card key={s.seller_id} className={`flex items-center gap-3 px-4 ${tv ? 'py-5' : 'py-4'}`}>
              <span className={`flex size-10 shrink-0 items-center justify-center rounded-full text-lg font-bold ${MEDAL[i]}`}>{i + 1}º</span>
              <span className="min-w-0">
                <span className={`block truncate font-semibold text-ink ${tv ? 'text-xl' : ''}`}>{s.name}</span>
                <span className={`num block text-ink-soft ${tv ? 'text-lg' : 'text-sm'}`}>{brlText(amountOf(s))} · {countOf(s)} contrato(s)</span>
              </span>
            </Card>
          ))}
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-[1.6fr_1fr]">
        <Card className="overflow-hidden">
          <CardHeader title={<span className="flex items-center gap-2"><Trophy size={16} aria-hidden />Ranking</span>} />
          <div className="overflow-x-auto">
            <table className={`w-full min-w-[520px] text-left ${tv ? 'text-base' : 'text-sm'}`}>
              <thead className="bg-surface-muted text-xs font-semibold text-muted">
                <tr><th className="w-12 px-4 py-2.5">#</th><th className="px-4 py-2.5">Vendedor</th><th className="px-4 py-2.5 text-right">{METRICS[metric]}</th><th className="px-4 py-2.5 text-right">Contratos</th><th className="px-4 py-2.5">Meta do mês</th></tr>
              </thead>
              <tbody>
                {rows.length === 0 && <tr><td colSpan={5} className="px-4 py-6 text-center text-muted">Nenhuma venda no período.</td></tr>}
                {rows.map((s, i) => {
                  const g = s.goal ? pct(s.paid_amount, s.goal) : null
                  return (
                    <tr key={s.seller_id} className="border-t border-line">
                      <td className="num px-4 py-2.5 text-muted">{countOf(s) > 0 ? `${i + 1}º` : '—'}</td>
                      <td className="px-4 py-2.5 font-medium text-ink">{s.name}</td>
                      <td className="num px-4 py-2.5 text-right font-semibold text-ink">{brlText(amountOf(s))}</td>
                      <td className="num px-4 py-2.5 text-right text-ink-soft">{countOf(s)}</td>
                      <td className="px-4 py-2.5">{g === null ? <span className="text-xs text-muted">—</span> : (
                        <span className="flex items-center gap-2"><span className="h-1.5 w-20 overflow-hidden rounded-full bg-[#F3F1EC]"><span className="block h-1.5 rounded-full bg-brand" style={{ width: `${g}%` }} /></span><span className="num text-xs text-ink-soft">{g}%</span></span>
                      )}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          {metric === 'paga' && board.totals.no_seller_paid > 0 && <p className="border-t border-line px-4 py-2.5 text-xs text-[#92400E]">{board.totals.no_seller_paid} contrato(s) pago(s) sem vendedor ficaram fora do ranking.</p>}
        </Card>

        <div className="grid content-start gap-4">
          <Card>
            <CardHeader title="Funil do período" />
            <ul className="grid gap-2 px-5 pb-5 pt-3 text-sm">
              {[['Leads novos', funnel.leads], ['Contratos digitados', funnel.typed], ['Contratos pagos', funnel.paid]].map(([k, n], i, all) => (
                <li key={String(k)} className="flex items-center justify-between gap-2">
                  <span className="text-ink-soft">{k}</span>
                  <span className="num font-semibold text-ink">{n}{i > 0 && Number(all[i - 1][1]) > 0 && <span className="ml-2 text-xs font-normal text-muted">{Math.round((Number(n) / Number(all[i - 1][1])) * 100)}%</span>}</span>
                </li>
              ))}
            </ul>
          </Card>
          <Card>
            <CardHeader title="Últimos pagos ao cliente" />
            <ul className="px-5 pb-4 pt-2 text-sm">
              {board.last_paid.length === 0 && <li className="py-2 text-muted">Nenhum no período.</li>}
              {board.last_paid.map((l, i) => (
                <li key={i} className="flex items-center justify-between gap-2 border-t border-line py-2 first:border-t-0">
                  <span className="min-w-0 truncate text-ink">{l.name}</span>
                  <span className="num shrink-0 text-ink-soft">{brlText(l.amount)} · {day(l.paid_on)}</span>
                </li>
              ))}
            </ul>
          </Card>
        </div>
      </div>
      <p className="mt-4 text-xs text-muted">Produção paga: valor liberado dos contratos pagos ao cliente no período. Produção digitada: contratos cadastrados no período, sem cancelados e recusados. Comissão e repasse não aparecem aqui.</p>
    </>
  )

  if (tv) {
    return (
      <div className="fixed inset-0 z-50 overflow-y-auto bg-canvas px-6 py-6">
        <AutoRefresh seconds={60} />
        <h1 className="mb-4 flex items-center gap-2 text-3xl font-semibold tracking-tight text-ink"><Trophy size={28} aria-hidden />Ranking de vendas · {ctx.organization.name}</h1>
        {content}
      </div>
    )
  }
  return (
    <section>
      <PageHeader title="Ranking de vendas" description="Quem vendeu o quê no período. A equipe toda vê; comissão e repasse não aparecem." />
      {content}
    </section>
  )
}
