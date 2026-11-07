import Link from 'next/link'
import type { ReactNode } from 'react'
import { PageHeader } from '@/components/ui'
import { add, cmp, div, fromDecimalString, isZero, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'
import { Donut, Gauge, ProductionChart, SERIES, ShareBar, StackBar, Waterfall } from './dashboard-charts'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Totals = { contracts: number; production: number; expected: number; margin: number; sellers: number; received: number }
type Board = {
  period: { from: string; to: string; prev_from: string; prev_to: string; by_month: boolean }
  current: Totals; previous: Totals
  attention: Record<'bank_late' | 'bank_waiting' | 'to_pay', { n: number; amount: number }> & Record<'divergent' | 'no_calc' | 'stale' | 'overdue', { n: number }>
  series: { day: string; production: number; contracts: number }[]
  sellers: { id: string | null; name: string; contracts: number; production: number; payable: number }[]
  banks: { id: string | null; name: string; contracts: number; production: number; expected: number; missing: number }[]
  pipeline: Record<string, number>
}
// Open cases from pipeline_case_list (RLS of the caller); money arrives as text.
type OpenCase = { id: string; proposal_id: string; canonical_state: string; entered_stage_at: string; due_at: string | null
  requested_amount: string | null; released_amount: string | null; full_name: string | null; bank: string | null; seller_name: string | null }
type OpenList = { open: number; rows: OpenCase[] }

export const PERIODS = { hoje: 'Hoje', '7d': '7 dias', mes: 'Mês', ano: 'Ano' } as const
export type PeriodKey = keyof typeof PERIODS

const iso = (d: Date) => d.toISOString().slice(0, 10)
const utc = (y: number, m: number, d: number) => new Date(Date.UTC(y, m, d))
// The period and the one it is compared with, in São Paulo dates: the month and the year to date compare with the
// same days of the previous month or year; today and 7 days with the days just before.
export function periodRange(key: PeriodKey) {
  const [y, m, d] = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date()).split('-').map(Number)
  const today = utc(y, m - 1, d)
  const shift = (dt: Date, days: number) => new Date(dt.getTime() + days * 86_400_000)
  // "Banco não pagou há mais de 30 dias": paid to the client on or before this day (owner_dashboard: < today - 30).
  const lateUntil = iso(shift(today, -31))
  if (key === 'hoje') return { from: iso(today), to: iso(today), prevFrom: iso(shift(today, -1)), prevTo: iso(shift(today, -1)), label: 'ontem', lateUntil }
  if (key === '7d') return { from: iso(shift(today, -6)), to: iso(today), prevFrom: iso(shift(today, -13)), prevTo: iso(shift(today, -7)), label: '7 dias anteriores', lateUntil }
  if (key === 'ano') return { from: iso(utc(y, 0, 1)), to: iso(today), prevFrom: iso(utc(y - 1, 0, 1)), prevTo: iso(utc(y - 1, m - 1, Math.min(d, new Date(Date.UTC(y - 1, m, 0)).getUTCDate()))), label: 'mesmo período do ano passado', lateUntil }
  const lastPrev = new Date(Date.UTC(y, m - 1, 0)).getUTCDate()
  return { from: iso(utc(y, m - 1, 1)), to: iso(today), prevFrom: iso(utc(y, m - 2, 1)), prevTo: iso(utc(y, m - 2, Math.min(d, lastPrev))), label: 'mesmos dias do mês passado', lateUntil }
}

const R = (v: number | string | null | undefined) => fromDecimalString(String(v ?? 0))
const ZERO = R(0)
const fix = (r: Rational) => toDecimalString(r, 2)
const money = (v: number | string) => brlText(fix(R(v)))
const MONTHS = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']
const WEEKDAYS = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado']
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

// "R$ 1.284.350,00" with the currency and the cents stepped back; `minus` prints "− R$ ..." for deductions.
function Money({ v, minus = false, round = false }: { v: Rational | number | string; minus?: boolean; round?: boolean }) {
  const r = typeof v === 'object' ? v : R(v)
  const neg = cmp(r, ZERO) < 0
  const text = brlText(fix(neg ? sub(ZERO, r) : r)).replace(/^R\$ /, '')
  const [reais, cents] = text.split(',')
  return (
    <span className="num whitespace-nowrap">
      {minus || neg ? '− ' : ''}<span className="money-cur">R$</span>{reais}{round ? null : <span className="money-cents">,{cents}</span>}
    </span>
  )
}

function periodText(key: PeriodKey, from: string, to: string): string {
  const [y, m, d] = to.split('-').map(Number)
  const weekday = WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]
  if (key === 'hoje') return `Hoje, ${weekday}, ${d} de ${MONTHS[m - 1]}`
  if (key === 'mes') return `${MONTHS[m - 1][0].toUpperCase()}${MONTHS[m - 1].slice(1)} de ${y}, até hoje (${weekday}, ${d})`
  if (key === 'ano') return `${y}, até hoje (${d} de ${MONTHS[m - 1]})`
  const [, fm, fd] = from.split('-').map(Number)
  return `De ${fd} de ${MONTHS[fm - 1]} até hoje (${weekday}, ${d})`
}
const dayLabel = (d: string, byMonth: boolean) => {
  const [y, m, day] = d.split('-')
  return byMonth ? ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'][Number(m) - 1] + `/${y.slice(2)}` : `${day}/${m}`
}
const STATE_LABEL: Record<string, string> = {
  digitization_queue: 'Fila de digitação', digitizing: 'Digitando', submitted: 'No banco', pending_external: 'Pendência', approved: 'Aprovado',
}
// Server-rendered per request.
const requestTime = () => Date.now()

const panel = 'rounded-[10px] border border-line bg-surface shadow-[0_1px_2px_rgba(17,26,46,0.04)]'
const rowLink = 'hover:underline decoration-line-strong underline-offset-4'
const linkCls = 'text-[13.5px] font-bold text-brand-strong hover:underline'
// Pipeline stage colors (company palette); red stays reserved for late cases.
const STATE_COLOR: Record<string, string> = {
  digitization_queue: 'var(--chart-3)', digitizing: 'var(--chart-3)', submitted: 'var(--chart-4)', pending_external: 'var(--chart-2)', approved: 'var(--chart-5)',
}
// Drawing only: pixel geometry from the exact decimal (text amounts never come from this number).
const px = (v: Rational | number | string) => Number(toDecimalString(typeof v === 'object' ? v : R(v), 2))
const milText = (v: number) => (v >= 1000 ? `${new Intl.NumberFormat('pt-BR', { maximumFractionDigits: v >= 100_000 ? 0 : 1 }).format(v / 1000)} mil` : String(Math.round(v)))
const cap = (t: string) => t[0].toUpperCase() + t.slice(1)

function PanelHead({ id, title, right }: { id: string; title: string; right?: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3 px-5 pt-4">
      <h2 id={id} className="text-[15.5px] font-bold tracking-tight text-ink">{title}</h2>
      {right}
    </div>
  )
}

// The owner's dashboard (visual "cores da empresa", owner 07/11/2026): pending items with their action on top, production
// of the period as a cumulative line, commission by bank, what the banks already paid, the period's result as a waterfall
// from the expected commission to what stays in the company, the pipeline by stage, stuck cases and sellers. Every number
// opens the list behind it. All money comes from owner_dashboard and pipeline_case_list (numeric as text, exact arithmetic);
// the only derived line is "impostos e outras comissões" = expected − sellers − margin, the same terms the margin uses.
export async function OwnerDashboard({ supabase, organizationId, organizationName, period, allAlertsHref = '/app/hoje' }: { supabase: Supa; organizationId: string; organizationName?: string; period: PeriodKey; allAlertsHref?: string }) {
  const range = periodRange(period)
  const [{ data, error }, { data: openData }] = await Promise.all([
    supabase.rpc('owner_dashboard', { p_org: organizationId, p_from: range.from, p_to: range.to, p_prev_from: range.prevFrom, p_prev_to: range.prevTo }),
    supabase.rpc('pipeline_case_list', { p_org: organizationId, p_limit: 1000, p_filters: {} }),
  ])
  const board = data as Board | null
  const paidLink = (extra: Record<string, string> = {}) => `/app/contratos?${new URLSearchParams({ situacao: 'paid', pago_de: range.from, pago_ate: range.to, n: '100', ...extra })}`

  const header = (
    <PageHeader title="Visão geral" description={periodText(period, range.from, range.to)}
      actions={<nav aria-label="Período" className="inline-flex rounded-lg border border-line bg-surface p-[3px]">
        {(Object.keys(PERIODS) as PeriodKey[]).map(k => (
          <Link key={k} href={`/app?periodo=${k}`} aria-current={k === period ? 'page' : undefined}
            className={`rounded-[5px] px-3.5 py-1.5 text-[13.5px] font-semibold ${k === period ? 'bg-brand text-white' : 'text-ink-soft hover:text-ink'}`}>{PERIODS[k]}</Link>
        ))}
      </nav>} />
  )
  if (error || !board) return <section>{header}<div className={`${panel} p-5 text-sm text-diverged`}>Não foi possível carregar os números agora. Tente de novo em instantes.</div></section>
  void organizationName

  const { current: cur, previous: prev, attention: at } = board
  const open = (openData ?? { open: 0, rows: [] }) as OpenList
  const openRows = open.rows ?? []
  const openComplete = (open.open ?? 0) <= openRows.length
  const now = requestTime()

  // Pending items: a sentence, the amount when there is one, and the action that solves it.
  const tasks: { tone: 'danger' | 'warn'; n: number; text: string; value: number | null; action: string; href: string; primary: boolean }[] = [
    { tone: 'danger' as const, n: at.bank_late.n, text: `${plural(at.bank_late.n, 'contrato', 'contratos')} com comissão do banco atrasada há mais de 30 dias`, value: at.bank_late.amount, action: 'Cobrar', href: `/app/contratos?repasse=banco&pago_ate=${range.lateUntil}&n=100`, primary: true },
    { tone: 'danger' as const, n: at.overdue.n, text: `${plural(at.overdue.n, 'contrato parado', 'contratos parados')} além do prazo da etapa`, value: null, action: 'Ver contratos', href: '/app/propostas?atrasado=1', primary: false },
    { tone: 'warn' as const, n: at.to_pay.n, text: `Repasse a pagar para ${plural(at.to_pay.n, 'vendedor', 'vendedores')}`, value: at.to_pay.amount, action: 'Pagar', href: '/app/repasse#pagar', primary: true },
    { tone: 'warn' as const, n: at.divergent.n, text: `${plural(at.divergent.n, 'comissão do banco diferente', 'comissões do banco diferentes')} do previsto`, value: null, action: 'Conferir', href: '/app/contratos?repasse=divergente&n=100', primary: false },
    { tone: 'warn' as const, n: at.no_calc.n, text: `${plural(at.no_calc.n, 'contrato pago', 'contratos pagos')} sem comissão calculada`, value: null, action: 'Calcular', href: '/app/contratos?comissao=pendente&situacao=paid&n=100', primary: false },
    { tone: 'warn' as const, n: at.stale.n, text: `${plural(at.stale.n, 'comissão desatualizada', 'comissões desatualizadas')} (vendedor ou grupo mudou)`, value: null, action: 'Recalcular', href: '/app/contratos?desatualizado=1&n=100', primary: false },
  ].filter(t => t.n > 0)

  // The statement. costs = expected − sellers − margin (tax, IR, supervisor, manager), as owner_dashboard defines margin.
  const expected = R(cur.expected)
  const sellers = R(cur.sellers)
  const margin = R(cur.margin)
  const costs = sub(sub(expected, sellers), margin)
  const missing = board.banks.reduce((s, b) => add(s, R(b.missing)), ZERO)
  const receivedOfThese = sub(expected, missing)
  const receivedPct = isZero(expected) ? null : Number(toDecimalString(mul(div(receivedOfThese, expected), R(100)), 0))
  const marginDiff = sub(margin, R(prev.margin))
  const hasPrev = prev.contracts > 0

  // Banks by expected commission, one color each; past 4 banks the rest is grouped.
  const banksSorted = [...board.banks].sort((a, b) => cmp(R(b.expected), R(a.expected)))
  const bankColor = (i: number) => SERIES[Math.min(i, SERIES.length - 1)]
  const bankRest = banksSorted.slice(4)
  const bankRows = [
    ...banksSorted.slice(0, 4).map((b, i) => ({ key: b.id ?? 'none', name: b.name, href: paidLink({ banco: b.id ?? 'none' }), expected: R(b.expected), missing: R(b.missing), color: bankColor(i) })),
    ...(bankRest.length ? [{ key: 'rest', name: `Outros ${bankRest.length}`, href: paidLink(), expected: bankRest.reduce((s, b) => add(s, R(b.expected)), ZERO), missing: bankRest.reduce((s, b) => add(s, R(b.missing)), ZERO), color: SERIES[4] }] : []),
  ]
  const topMissingKey = [...bankRows].sort((a, b) => cmp(b.missing, a.missing))[0]?.key
  const pctOf = (part: Rational, whole: Rational) => (isZero(whole) ? '0' : toDecimalString(mul(div(part, whole), R(100)), 1).replace('.', ','))

  // Pipeline: counts from owner_dashboard; value and late cases from the open list (shown only when the list is whole).
  const states = Object.keys(STATE_LABEL).filter(s => (board.pipeline[s] ?? 0) > 0)
    .concat(Object.keys(board.pipeline).filter(s => !(s in STATE_LABEL) && board.pipeline[s] > 0))
  const amountOf = (c: OpenCase) => R(c.released_amount ?? c.requested_amount ?? 0)
  const isLate = (c: OpenCase) => c.due_at !== null && new Date(c.due_at).getTime() < now
  const byState = (s: string) => openRows.filter(c => c.canonical_state === s)
  const openTotal = Object.values(board.pipeline).reduce((a, b) => a + b, 0)
  const openValue = openRows.reduce((a, c) => add(a, amountOf(c)), ZERO)
  const stuck = openRows.filter(isLate).sort((a, b) => a.entered_stage_at.localeCompare(b.entered_stage_at)).slice(0, 6)
  const daysIn = (c: OpenCase) => Math.max(0, Math.floor((now - new Date(c.entered_stage_at).getTime()) / 86_400_000))
  const stateColor = (s: string) => STATE_COLOR[s] ?? 'var(--expected)'

  // Production per day (or month): every slot of the period, the empty ones too, so the gaps show.
  const byDay = new Map(board.series.map(s => [s.day, s]))
  const slots: string[] = []
  for (let d = new Date(`${board.period.from}T12:00:00Z`); iso(d) <= board.period.to; d = board.period.by_month ? new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1, 12)) : new Date(d.getTime() + 86_400_000))
    slots.push(board.period.by_month ? iso(d).slice(0, 8) + '01' : iso(d))
  const series = slots.map(day => byDay.get(day) ?? { day, production: 0, contracts: 0 })
  const prodDiff = sub(R(cur.production), R(prev.production))
  const prodPct = isZero(R(prev.production)) ? null : toDecimalString(mul(div(prodDiff, R(prev.production)), R(100)), 1).replace('.', ',')

  const sellerTotal = board.sellers.reduce((s, x) => add(s, R(x.production)), ZERO)

  const isNewCompany = cur.contracts === 0 && prev.contracts === 0 && openTotal === 0 && board.sellers.length === 0

  if (isNewCompany) return (
    <section>
      {header}
      <div className={`${panel} max-w-xl p-5`}>
        <h2 className="text-[15.5px] font-bold text-ink">Resultado do período</h2>
        <p className="mt-2 text-[15px] text-ink">Nenhum contrato pago ainda.</p>
        <p className="mt-1 text-[13px] text-muted">Importe a planilha de produção do banco e o resultado aparece aqui, já com a comissão prevista e o repasse de cada vendedor.</p>
        <div className="mt-5 flex flex-wrap gap-2">
          <Link href="/app/propostas/importar" className="rounded-[7px] bg-brand px-4 py-2 text-[13.5px] font-bold text-white hover:bg-brand-strong">Importar planilha do banco</Link>
          <Link href="/app/cadastros/vendedores" className="rounded-[7px] border border-line-strong bg-surface px-4 py-2 text-[13.5px] font-bold text-ink hover:bg-surface-muted">Cadastrar vendedor</Link>
        </div>
      </div>
    </section>
  )

  const th = 'pb-2 text-[12.5px] font-semibold text-muted'
  const td = 'border-t border-line py-2.5'
  const up = (r: Rational) => cmp(r, ZERO) >= 0

  return (
    <section>
      {header}

      {tasks.length === 0 ? (
        <p className={`${panel} mb-5 flex items-center justify-between gap-3 px-5 py-4 text-sm text-muted`}>
          Nada fora do normal no dinheiro e nos contratos.
          <Link href={allAlertsHref} className={linkCls}>Ver leads e tarefas</Link>
        </p>
      ) : (
        <div aria-label="Pendências" className={`${panel} mb-5 grid divide-y divide-line sm:grid-cols-2 sm:divide-y-0 xl:grid-cols-4 xl:divide-x`}>
          {tasks.slice(0, 4).map(t => (
            <div key={t.text} className="flex flex-col gap-1.5 px-[18px] py-4">
              <span className={`flex items-center gap-2 text-[12.5px] font-bold ${t.tone === 'danger' ? 'text-reversed' : 'text-diverged'}`}>
                <i className={`size-2 rounded-full ${t.tone === 'danger' ? 'bg-reversed' : 'bg-[#e59a12]'}`} />{t.tone === 'danger' ? 'Atrasado' : 'Atenção'}
              </span>
              <Link href={t.href} className="text-[14.5px] font-semibold leading-snug text-ink hover:underline">{t.text}</Link>
              <div className="mt-auto flex items-center justify-between gap-3 pt-2">
                <span className={`text-base font-extrabold ${t.tone === 'danger' ? 'text-reversed' : 'text-ink'}`}>{t.value !== null ? <Money v={t.value} /> : plural(t.n, 'contrato', 'contratos')}</span>
                <Link href={t.href} className={`shrink-0 rounded-[7px] border px-3.5 py-1.5 text-[13.5px] font-bold ${t.primary ? 'border-brand bg-brand text-white hover:bg-brand-strong' : 'border-line-strong bg-surface text-ink hover:bg-surface-muted'}`}>{t.action}</Link>
              </div>
            </div>
          ))}
          {tasks.length > 4 ? <p className="col-span-full border-t border-line px-5 py-2 text-right"><Link href={allAlertsHref} className="text-[12.5px] text-muted hover:text-ink hover:underline">Mais {tasks.length - 4} em todos os alertas</Link></p> : null}
        </div>
      )}

      <div className="mb-5 grid gap-5 xl:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <section className={panel} aria-labelledby="t-producao">
          <PanelHead id="t-producao" title="Produção do período" right={<Link href={paidLink()} className={linkCls}>Ver contratos pagos</Link>} />
          <div className="flex flex-wrap items-end gap-x-10 gap-y-2 px-5 pt-2">
            <div>
              <div className="text-[13px] text-muted">Produção paga</div>
              <div className="flex flex-wrap items-baseline gap-x-2 text-[26px] font-extrabold tracking-tight text-ink"><Money v={cur.production} /><span className="text-[14px] font-semibold tracking-normal text-ink-soft">{plural(cur.contracts, 'contrato', 'contratos')}</span></div>
            </div>
            {hasPrev ? (
              <div>
                <div className="text-[13px] text-muted">{cap(range.label)}</div>
                <div className="flex items-center gap-2 text-[18px] font-bold text-ink-soft"><Money v={prev.production} />
                  {prodPct !== null ? <span className={`rounded-full px-2 py-0.5 text-[12.5px] font-bold ${up(prodDiff) ? 'bg-[#e7f5ec] text-received' : 'bg-[#fdedec] text-reversed'}`}>{up(prodDiff) ? '+' : ''}{prodPct}%</span> : null}
                </div>
              </div>
            ) : null}
          </div>
          <div className="px-3 pb-3 pt-2">
            {cur.contracts === 0 ? <p className="px-2 py-10 text-center text-sm text-muted">Nenhum contrato pago ao cliente neste período.</p> : (
              <ProductionChart
                points={series.map(s => ({ label: dayLabel(s.day, board.period.by_month), value: px(s.production), href: board.period.by_month ? paidLink() : paidLink({ pago_de: s.day, pago_ate: s.day }), title: `${dayLabel(s.day, board.period.by_month)}: ${money(s.production)}, ${plural(s.contracts, 'contrato', 'contratos')}` }))}
                axisLabel={milText}
                lastLabel={`R$ ${milText(px(cur.production))}`}
              />
            )}
          </div>
        </section>

        <section className={panel} aria-labelledby="t-bancos-comissao">
          <PanelHead id="t-bancos-comissao" title="Comissão por banco" right={<span className="text-[13px] text-muted">prevista</span>} />
          {bankRows.length === 0 ? <p className="px-5 py-10 text-center text-sm text-muted">Sem produção paga neste período.</p> : (
            <div className="flex flex-col gap-4 px-5 pb-4 pt-4">
              <Donut items={bankRows.map(b => ({ value: px(b.expected), color: b.color }))} center={<Money v={expected} />} sub="comissão prevista" />
              <div>{bankRows.map(b => (
                <Link key={b.key} href={b.href} className="grid grid-cols-[12px_minmax(0,1fr)_auto_48px] items-center gap-2.5 border-t border-line py-2 text-[13.5px] hover:bg-surface-muted">
                  <i className="size-3 rounded-[3px]" style={{ background: b.color }} />
                  <span className="truncate font-semibold text-ink">{b.name}</span>
                  <span className="font-semibold text-ink"><Money v={b.expected} /></span>
                  <span className="text-right text-[12.5px] text-muted">{pctOf(b.expected, expected)}%</span>
                </Link>
              ))}</div>
            </div>
          )}
        </section>
      </div>

      <div className="mb-5 grid gap-5 xl:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
        <section className={panel} aria-labelledby="t-resultado">
          <PanelHead id="t-resultado" title="Resultado do período" right={<Link href={paidLink()} className={linkCls}>Ver contratos</Link>} />
          <div className="flex flex-wrap items-center justify-between gap-2 px-5 pt-1.5 text-[13.5px] text-ink-soft">
            <span>Produção paga: <b className="text-ink"><Money v={cur.production} /></b> em {plural(cur.contracts, 'contrato', 'contratos')}</span>
            {hasPrev ? <span className={`rounded-full px-2.5 py-1 text-[13px] ${up(marginDiff) ? 'bg-[#e7f5ec]' : 'bg-[#fdedec]'}`}>{cap(range.label)}: <Money v={prev.margin} /> <b className={up(marginDiff) ? 'text-received' : 'text-reversed'}>{up(marginDiff) ? '+ ' : ''}<Money v={marginDiff} /></b></span> : null}
          </div>
          <div className="px-3 pb-4 pt-3">
            <Waterfall steps={[
              { label: 'Comissão prevista dos bancos', amount: <Money v={expected} />, value: px(expected), kind: 'start', color: 'var(--chart-3)', href: paidLink() },
              ...(!isZero(costs) ? [{ label: 'Impostos, IR, supervisão e gerência', amount: <Money v={costs} minus />, value: px(costs), kind: 'minus' as const, color: 'var(--chart-2)', href: paidLink() }] : []),
              { label: 'Repasse aos vendedores', amount: <Money v={sellers} minus />, value: px(sellers), kind: 'minus', color: 'var(--chart-4)', href: '/app/repasse' },
              { label: 'Fica na empresa', amount: <Money v={margin} />, value: px(margin), kind: 'total', color: 'var(--brand)', href: paidLink() },
            ]} />
          </div>
        </section>

        <section className={panel} aria-labelledby="t-recebimento">
          <PanelHead id="t-recebimento" title="Recebimento dos bancos" right={<Link href={`/app/financeiro/conciliacao?${new URLSearchParams({ de: range.from, ate: range.to })}`} className={linkCls}>Conciliar</Link>} />
          {receivedPct === null ? <p className="px-5 py-10 text-center text-sm text-muted">Sem comissão prevista neste período.</p> : (
            <div className="px-5 pb-4 pt-4">
              <Gauge pct={receivedPct} parts={bankRows.map(b => ({ value: px(sub(b.expected, b.missing)), color: b.color }))} />
              <div className="mt-4 flex justify-between gap-3">
                <div><div className="text-[12.5px] text-muted">Recebido</div><div className="text-[17px] font-extrabold text-ink"><Money v={receivedOfThese} /></div></div>
                <div className="text-right"><div className="text-[12.5px] text-muted">Falta receber</div><div className="text-[17px] font-extrabold text-ink"><Money v={missing} /></div></div>
              </div>
              <div className="mt-3">{bankRows.map(b => (
                <div key={b.key} className="grid grid-cols-[10px_minmax(0,1fr)_auto] items-center gap-2.5 border-t border-line py-2 text-[13px]">
                  <i className="size-2.5 rounded-[2px]" style={{ background: b.color }} />
                  <span className="truncate text-ink">{b.name}</span>
                  <span className={isZero(b.missing) ? 'text-muted' : b.key === topMissingKey ? 'font-bold text-reversed' : 'text-ink-soft'}>{isZero(b.missing) ? 'nada a receber' : <>falta <Money v={b.missing} /></>}</span>
                </div>
              ))}</div>
            </div>
          )}
        </section>
      </div>

      <div className="mb-5 grid gap-5 xl:grid-cols-2">
        <section className={panel} aria-labelledby="t-esteira">
          <PanelHead id="t-esteira" title="Esteira agora" right={<Link href="/app/propostas" className={linkCls}>Abrir esteira</Link>} />
          {states.length === 0 ? <p className="px-5 py-10 text-center text-sm text-muted">Nenhum contrato em andamento.</p> : (
            <div className="px-5 pb-3 pt-3">
              <StackBar items={states.map(s => ({ value: board.pipeline[s], color: stateColor(s), label: STATE_LABEL[s] ?? s, href: `/app/propostas?estado=${s}` }))} />
              <div className="mt-1.5 flex justify-between text-[12.5px] text-muted"><span>{plural(openTotal, 'contrato em andamento', 'contratos em andamento')}</span>{openComplete ? <Money v={openValue} /> : null}</div>
              <table className="mt-2 w-full border-collapse text-[13.5px] text-ink">
                <tbody>{states.map(s => {
                  const rows = byState(s)
                  const late = rows.filter(isLate).length
                  return (
                    <tr key={s}>
                      <td className={td}><Link href={`/app/propostas?estado=${s}`} className={`flex items-center gap-2.5 ${rowLink}`}><i className="size-2.5 rounded-[2px]" style={{ background: stateColor(s) }} />{STATE_LABEL[s] ?? s}</Link></td>
                      <td className={`num ${td} text-right font-semibold`}>{board.pipeline[s]}</td>
                      <td className={`${td} text-right`}>{openComplete ? <Money v={rows.reduce((a, c) => add(a, amountOf(c)), ZERO)} /> : '—'}</td>
                      <td className={`${td} text-right`}>{openComplete ? (late ? <Link href="/app/propostas?atrasado=1" className="whitespace-nowrap rounded-full bg-[#fdedec] px-2 py-0.5 text-[12.5px] font-bold text-reversed">{plural(late, 'atrasado', 'atrasados')}</Link> : <span className="text-[12.5px] text-muted">em dia</span>) : '—'}</td>
                    </tr>
                  )
                })}</tbody>
              </table>
              {!openComplete ? <p className="mt-2 text-[12px] text-muted">Valor e atrasados por etapa aparecem até 1.000 contratos em andamento; acima disso, veja na Esteira.</p> : null}
            </div>
          )}
        </section>

        <section className={panel} aria-labelledby="t-parados">
          <PanelHead id="t-parados" title="Parados há mais tempo" right={<Link href="/app/propostas?atrasado=1" className={linkCls}>Ver todos</Link>} />
          {stuck.length === 0 ? <p className="px-5 py-10 text-center text-sm text-muted">Nenhum contrato além do prazo da etapa.</p> : (
            <div className="overflow-x-auto px-5 pb-3 pt-3">
              <table className="w-full border-collapse text-[13.5px] text-ink">
                <thead><tr><th className={`${th} text-left`}>Cliente</th><th className={`${th} text-left`}>Etapa</th><th className={`${th} hidden text-left sm:table-cell`}>Banco</th><th className={`${th} text-right`}>Valor</th><th className={`${th} whitespace-nowrap pl-3 text-right`}>Parado há</th></tr></thead>
                <tbody>{stuck.map(c => {
                  const d = daysIn(c)
                  return (
                    <tr key={c.id}>
                      <td className={`${td} max-w-[180px] truncate pr-3`}><Link href={`/app/propostas/${c.proposal_id}`} className={rowLink}>{c.full_name ?? 'Cliente sem nome'}</Link></td>
                      <td className={`${td} pr-3`}><span className="whitespace-nowrap rounded-md bg-surface-muted px-2 py-0.5 text-[12.5px] font-semibold text-ink-soft ring-1 ring-line">{STATE_LABEL[c.canonical_state] ?? c.canonical_state}</span></td>
                      <td className={`${td} hidden whitespace-nowrap pr-3 text-ink-soft sm:table-cell`}>{c.bank ?? '—'}</td>
                      <td className={`${td} text-right`}><Money v={amountOf(c)} /></td>
                      <td className={`${td} whitespace-nowrap pl-3 text-right font-bold ${d >= 30 ? 'text-reversed' : 'text-diverged'}`}>{plural(d, 'dia', 'dias')}</td>
                    </tr>
                  )
                })}</tbody>
              </table>
            </div>
          )}
        </section>
      </div>

      <div className="grid gap-5 xl:grid-cols-2">
        <section className={panel} aria-labelledby="t-vendedores">
          <PanelHead id="t-vendedores" title="Vendedores no período" right={<Link href="/app/repasse" className={linkCls}>Ver repasse</Link>} />
          {board.sellers.length === 0 ? <p className="px-5 py-10 text-center text-sm text-muted">Sem produção paga neste período.</p> : (
            <div className="overflow-x-auto px-5 pb-3 pt-3">
              <table className="w-full border-collapse text-[13.5px] text-ink">
                <thead><tr><th className={`${th} text-left`}>Vendedor</th><th className={`${th} text-right`}>Produção</th><th className={`${th} hidden w-[28%] pl-4 text-left md:table-cell`}>Participação</th><th className={`${th} text-right`}>Recebe</th></tr></thead>
                <tbody>{board.sellers.map(s => {
                  const share = isZero(sellerTotal) ? ZERO : mul(div(R(s.production), sellerTotal), R(100))
                  return (
                    <tr key={s.id ?? 'none'}>
                      <td className={`${td} pr-3`}><Link href={paidLink({ vendedor: s.id ?? 'none' })} className={`font-semibold ${rowLink}`}>{s.name}</Link> <span className="text-[12px] text-muted">{plural(s.contracts, 'contrato', 'contratos')}</span></td>
                      <td className={`${td} text-right`}><Money v={s.production} /></td>
                      <td className={`${td} hidden pl-4 md:table-cell`}><span className="flex items-center gap-2"><ShareBar pct={px(share)} /><span className="w-11 shrink-0 text-right text-[12.5px] text-muted">{toDecimalString(share, 1).replace('.', ',')}%</span></span></td>
                      <td className={`${td} text-right text-ink-soft`}><Money v={s.payable} /></td>
                    </tr>
                  )
                })}</tbody>
              </table>
            </div>
          )}
        </section>
        <section className={panel} aria-labelledby="t-bancos">
          <PanelHead id="t-bancos" title="Bancos no período" right={<Link href="/app/financeiro" className={linkCls}>Ver financeiro</Link>} />
          {board.banks.length === 0 ? <p className="px-5 py-10 text-center text-sm text-muted">Sem produção paga neste período.</p> : (
            <div className="overflow-x-auto px-5 pb-3 pt-3">
              <table className="w-full border-collapse text-[13.5px] text-ink">
                <thead><tr><th className={`${th} text-left`}>Banco</th><th className={`${th} text-right`}>Produção</th><th className={`${th} text-right`}>Comissão</th><th className={`${th} text-right`}>Falta receber</th></tr></thead>
                <tbody>{banksSorted.map((b, i) => (
                  <tr key={b.id ?? 'none'}>
                    <td className={`${td} pr-3`}><Link href={paidLink({ banco: b.id ?? 'none' })} className={`flex items-center gap-2 font-semibold ${rowLink}`}><i className="size-2.5 shrink-0 rounded-[2px]" style={{ background: bankColor(i) }} />{b.name}</Link></td>
                    <td className={`${td} text-right`}><Money v={b.production} round /></td>
                    <td className={`${td} text-right text-ink-soft`}><Money v={b.expected} /></td>
                    <td className={`${td} text-right ${cmp(R(b.missing), ZERO) > 0 ? 'font-semibold text-reversed' : 'text-muted'}`}>{cmp(R(b.missing), ZERO) > 0 ? <Money v={b.missing} /> : 'nada'}</td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
          )}
        </section>
      </div>
      <p className="mt-6 text-xs text-muted">Calculado na hora a partir dos contratos, recebimentos e repasses do Corban. Toque em qualquer número para ver os contratos por trás dele.</p>
    </section>
  )
}
