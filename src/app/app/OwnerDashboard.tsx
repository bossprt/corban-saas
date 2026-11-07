import Link from 'next/link'
import type { ReactNode } from 'react'
import { PageHeader } from '@/components/ui'
import { add, cmp, div, fromDecimalString, isZero, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'

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

const panel = 'rounded-[10px] border border-line bg-surface px-5 py-5 sm:px-6'
const rowLink = 'hover:underline decoration-line-strong underline-offset-4'

// The owner's dashboard, "Demonstrativo" (redesign 07/11/2026, research on Stripe, Mercury, Ramp, Linear, Attio):
// pending items as sentences with an action on top; the period as a statement that adds up from production to what
// stays in the company; the pipeline with value and late cases; the cases stuck the longest. Every number opens the
// list behind it. All money comes from owner_dashboard and pipeline_case_list (numeric as text, exact arithmetic);
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
    <PageHeader title="Visão geral" description={organizationName ? `${organizationName} · ${periodText(period, range.from, range.to)}` : periodText(period, range.from, range.to)}
      actions={<nav aria-label="Período" className="flex gap-0.5 rounded-[8px] border border-line bg-surface p-0.5">
        {(Object.keys(PERIODS) as PeriodKey[]).map(k => (
          <Link key={k} href={`/app?periodo=${k}`} aria-current={k === period ? 'page' : undefined}
            className={`rounded-[6px] px-3 py-1 text-[13px] ${k === period ? 'bg-ink font-medium text-surface' : 'text-muted hover:text-ink'}`}>{PERIODS[k]}</Link>
        ))}
      </nav>} />
  )
  if (error || !board) return <section>{header}<div className={`${panel} text-sm text-[#92400E]`}>Não foi possível carregar os números agora. Tente de novo em instantes.</div></section>

  const { current: cur, previous: prev, attention: at } = board
  const open = (openData ?? { open: 0, rows: [] }) as OpenList
  const openRows = open.rows ?? []
  const openComplete = (open.open ?? 0) <= openRows.length
  const now = requestTime()

  // Pending items: a sentence, the amount when there is one, and the action that solves it.
  const tasks: { tone: 'danger' | 'warn'; n: number; text: string; value: number | null; action: string; href: string }[] = [
    { tone: 'danger' as const, n: at.bank_late.n, text: `${plural(at.bank_late.n, 'contrato', 'contratos')} com comissão do banco atrasada há mais de 30 dias`, value: at.bank_late.amount, action: 'Cobrar', href: `/app/contratos?repasse=banco&pago_ate=${range.lateUntil}&n=100` },
    { tone: 'warn' as const, n: at.overdue.n, text: `${plural(at.overdue.n, 'contrato parado', 'contratos parados')} além do prazo da etapa`, value: null, action: 'Ver contratos', href: '/app/propostas?atrasado=1' },
    { tone: 'warn' as const, n: at.to_pay.n, text: `Repasse a pagar para ${plural(at.to_pay.n, 'vendedor', 'vendedores')}`, value: at.to_pay.amount, action: 'Pagar', href: '/app/repasse#pagar' },
    { tone: 'warn' as const, n: at.divergent.n, text: `${plural(at.divergent.n, 'comissão do banco diferente', 'comissões do banco diferentes')} do previsto`, value: null, action: 'Conferir', href: '/app/contratos?repasse=divergente&n=100' },
    { tone: 'warn' as const, n: at.no_calc.n, text: `${plural(at.no_calc.n, 'contrato pago', 'contratos pagos')} sem comissão calculada`, value: null, action: 'Calcular', href: '/app/contratos?comissao=pendente&situacao=paid&n=100' },
    { tone: 'warn' as const, n: at.stale.n, text: `${plural(at.stale.n, 'comissão desatualizada', 'comissões desatualizadas')} (vendedor ou grupo mudou)`, value: null, action: 'Recalcular', href: '/app/contratos?desatualizado=1&n=100' },
  ].filter(t => t.n > 0)

  // The statement. costs = expected − sellers − margin (tax, IR, supervisor, manager), as owner_dashboard defines margin.
  const expected = R(cur.expected)
  const sellers = R(cur.sellers)
  const margin = R(cur.margin)
  const costs = sub(sub(expected, sellers), margin)
  const missing = board.banks.reduce((s, b) => add(s, R(b.missing)), ZERO)
  const receivedOfThese = sub(expected, missing)
  const receivedPct = isZero(expected) ? null : Number(toDecimalString(mul(div(receivedOfThese, expected), R(100)), 0))
  const topMissing = [...board.banks].sort((a, b) => cmp(R(b.missing), R(a.missing)))[0]
  const marginDiff = sub(margin, R(prev.margin))
  const hasPrev = prev.contracts > 0

  // Pipeline: counts from owner_dashboard; value and late cases from the open list (shown only when the list is whole).
  const states = Object.keys(STATE_LABEL).filter(s => (board.pipeline[s] ?? 0) > 0)
    .concat(Object.keys(board.pipeline).filter(s => !(s in STATE_LABEL) && board.pipeline[s] > 0))
  const amountOf = (c: OpenCase) => R(c.released_amount ?? c.requested_amount ?? 0)
  const isLate = (c: OpenCase) => c.due_at !== null && new Date(c.due_at).getTime() < now
  const byState = (s: string) => openRows.filter(c => c.canonical_state === s)
  const openTotal = Object.values(board.pipeline).reduce((a, b) => a + b, 0)
  const stuck = openRows.filter(isLate).sort((a, b) => a.entered_stage_at.localeCompare(b.entered_stage_at)).slice(0, 6)
  const daysIn = (c: OpenCase) => Math.max(0, Math.floor((now - new Date(c.entered_stage_at).getTime()) / 86_400_000))

  // Production per day (or month): every slot of the period, the empty ones too, so the gaps show.
  const byDay = new Map(board.series.map(s => [s.day, s]))
  const slots: string[] = []
  for (let d = new Date(`${board.period.from}T12:00:00Z`); iso(d) <= board.period.to; d = board.period.by_month ? new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1, 12)) : new Date(d.getTime() + 86_400_000))
    slots.push(board.period.by_month ? iso(d).slice(0, 8) + '01' : iso(d))
  const series = slots.map(day => byDay.get(day) ?? { day, production: 0, contracts: 0 })
  const maxDay = series.reduce((m, s) => (cmp(R(s.production), m) > 0 ? R(s.production) : m), ZERO)
  const pct = (v: number | string, max: Rational) => (isZero(max) ? 0 : Math.max(2, Number(toDecimalString(mul(div(R(v), max), R(100)), 0))))

  const isNewCompany = cur.contracts === 0 && prev.contracts === 0 && openTotal === 0 && board.sellers.length === 0

  const line = (label: ReactNode, value: ReactNode, opts: { href?: string; note?: ReactNode; minor?: boolean; tone?: string } = {}) => (
    <tr className={opts.minor ? 'text-[13px] text-muted' : ''}>
      <td className={`border-b border-line py-2.5 pr-3 align-baseline ${opts.minor ? 'border-dashed pl-4' : ''} ${opts.tone ?? ''}`}>
        {opts.href ? <Link href={opts.href} className={rowLink}>{label}</Link> : label}
        {opts.note ? <span className="ml-2 text-[12.5px] text-muted">{opts.note}</span> : null}
      </td>
      <td className={`border-b border-line py-2.5 text-right align-baseline ${opts.minor ? 'border-dashed' : ''} ${opts.tone ?? ''}`}>
        {opts.href ? <Link href={opts.href} className={rowLink}>{value}</Link> : value}
      </td>
    </tr>
  )

  if (isNewCompany) return (
    <section>
      {header}
      <div className={`${panel} max-w-xl`}>
        <h2 className="text-[15px] font-semibold text-ink">Resultado do período</h2>
        <p className="mt-2 text-[15px] text-ink">Nenhum contrato pago ainda.</p>
        <p className="mt-1 text-[13px] text-muted">Importe a planilha de produção do banco e o resultado aparece aqui, já com a comissão prevista e o repasse de cada vendedor.</p>
        <table className="mt-4 w-full border-collapse text-sm text-muted">
          <tbody>{['Produção paga', 'Comissão prevista dos bancos', 'Repasse aos vendedores', 'Fica na empresa'].map(l => (
            <tr key={l}><td className="border-b border-line py-2.5">{l}</td><td className="border-b border-line py-2.5 text-right">—</td></tr>
          ))}</tbody>
        </table>
        <div className="mt-5 flex flex-wrap gap-2">
          <Link href="/app/propostas/importar" className="rounded-[7px] bg-brand px-4 py-2 text-[13.5px] font-medium text-white hover:bg-brand-strong">Importar planilha do banco</Link>
          <Link href="/app/cadastros/vendedores" className="rounded-[7px] border border-brand px-4 py-2 text-[13.5px] font-medium text-brand hover:bg-brand-soft">Cadastrar vendedor</Link>
        </div>
      </div>
    </section>
  )

  return (
    <section>
      {header}

      <div aria-label="Pendências" className="mb-7 border-t border-line">
        {tasks.length === 0 ? (
          <p className="flex items-center justify-between gap-3 border-b border-line px-1 py-3 text-sm text-muted">
            Nada fora do normal no dinheiro e nos contratos.
            <Link href={allAlertsHref} className="shrink-0 text-[13px] font-medium text-brand hover:underline">Ver leads e tarefas</Link>
          </p>
        ) : tasks.map(t => (
          <div key={t.text} className="flex items-center gap-3 border-b border-line px-1 py-2.5">
            <span aria-hidden className={`h-2 w-2 shrink-0 rounded-full ${t.tone === 'danger' ? 'bg-[#B42318]' : 'bg-[#B45309]'}`} />
            <span className="flex min-w-0 flex-1 flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5">
              <Link href={t.href} className="text-sm text-ink hover:underline">{t.text}</Link>
              {t.value !== null ? <span className="text-sm text-ink-soft"><Money v={t.value} /></span> : null}
            </span>
            <Link href={t.href} className="w-24 shrink-0 text-right text-[13px] font-medium text-brand hover:underline">{t.action}</Link>
          </div>
        ))}
        {tasks.length > 0 ? <p className="px-1 pt-2 text-right"><Link href={allAlertsHref} className="text-[12.5px] text-muted hover:text-ink hover:underline">Leads e tarefas ficam em todos os alertas</Link></p> : null}
      </div>

      <div className="mb-7 grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        <section className={panel} aria-labelledby="t-resultado">
          <h2 id="t-resultado" className="text-[15px] font-semibold text-ink">Resultado do período</h2>
          <p className="mb-3 text-[12.5px] text-muted">Dos contratos pagos ao cliente até o que fica na empresa</p>
          <table className="w-full border-collapse text-sm text-ink">
            <tbody>
              {line('Produção paga', <Money v={cur.production} />, { href: paidLink(), note: plural(cur.contracts, 'contrato', 'contratos') })}
              {line('Comissão prevista dos bancos', <Money v={expected} />, { href: paidLink() })}
              {!isZero(costs) ? line('Impostos, IR e comissões de supervisão e gerência', <Money v={costs} minus />, { minor: true, href: paidLink() }) : null}
              {line('Repasse aos vendedores', <Money v={sellers} minus />, { href: '/app/repasse' })}
              <tr>
                <td className="border-t-2 border-ink pt-3 text-base font-semibold">Fica na empresa</td>
                <td className="border-t-2 border-ink pt-3 text-right text-[22px] font-semibold"><Link href={paidLink()} className={rowLink}><Money v={margin} /></Link></td>
              </tr>
            </tbody>
          </table>
          <p className="mt-2 text-right text-[12.5px] text-muted">
            {hasPrev ? <>Comparado com {range.label}: <span className="text-ink"><Money v={prev.margin} /></span> ({cmp(marginDiff, ZERO) >= 0 ? '+ ' : ''}<Money v={marginDiff} />)</> : <>Sem contratos pagos em {range.label} para comparar.</>}
          </p>
        </section>

        <section className={panel} aria-labelledby="t-esteira">
          <h2 id="t-esteira" className="text-[15px] font-semibold text-ink">Esteira agora</h2>
          <p className="mb-3 text-[12.5px] text-muted">Contratos em andamento, por etapa</p>
          {states.length === 0 ? <p className="text-sm text-muted">Nenhum contrato em andamento.</p> : (
            <table className="w-full border-collapse text-[13.5px] text-ink">
              <thead><tr className="text-[12px] text-muted">
                <th className="pb-1.5 text-left font-medium">Etapa</th><th className="pb-1.5 text-right font-medium">Qtd.</th>
                <th className="pb-1.5 text-right font-medium">Valor</th><th className="pb-1.5 text-right font-medium">Atrasados</th>
              </tr></thead>
              <tbody>{states.map(s => {
                const rows = byState(s)
                const late = rows.filter(isLate).length
                return (
                  <tr key={s}>
                    <td className="border-b border-line py-2"><Link href={`/app/propostas?estado=${s}`} className={rowLink}>{STATE_LABEL[s] ?? s}</Link></td>
                    <td className="num border-b border-line py-2 text-right"><Link href={`/app/propostas?estado=${s}`} className={rowLink}>{board.pipeline[s]}</Link></td>
                    <td className="border-b border-line py-2 text-right">{openComplete ? <Money v={rows.reduce((a, c) => add(a, amountOf(c)), ZERO)} round /> : '—'}</td>
                    <td className={`num border-b border-line py-2 text-right ${late ? 'text-[#B42318]' : 'text-muted'}`}>{openComplete ? (late ? <Link href="/app/propostas?atrasado=1" className={rowLink}>{late}</Link> : '0') : '—'}</td>
                  </tr>
                )
              })}</tbody>
            </table>
          )}
          {!openComplete ? <p className="mt-2 text-[12px] text-muted">Valor e atrasados por etapa aparecem até 1.000 contratos em andamento; acima disso, veja na Esteira.</p> : null}

          <h3 className="mt-6 text-[13px] font-medium text-ink">Recebimento dos bancos</h3>
          <p className="mt-1 flex justify-between gap-3 text-[13px]"><Link href={`/app/financeiro/conciliacao?${new URLSearchParams({ de: range.from, ate: range.to })}`} className={`text-ink-soft ${rowLink}`}>Recebido no período</Link><Money v={cur.received} /></p>
          {receivedPct !== null ? (
            <>
              <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-line" role="img" aria-label={`${receivedPct}% da comissão prevista destes contratos já recebida`}>
                <span className="block h-full bg-brand" style={{ width: `${Math.min(100, Math.max(0, receivedPct))}%` }} />
              </div>
              <p className="mt-1.5 text-[12.5px] text-muted">
                {isZero(missing) ? 'Os bancos já pagaram toda a comissão dos contratos pagos no período.' : <>
                  {receivedPct}% da comissão destes contratos já entrou. Faltam <span className="text-ink"><Money v={missing} /></span>
                  {topMissing && !isZero(R(topMissing.missing)) && board.banks.filter(b => !isZero(R(b.missing))).length > 1 ? <>, dos quais <Money v={topMissing.missing} /> do {topMissing.name}</> : topMissing && !isZero(R(topMissing.missing)) ? <> do {topMissing.name}</> : null}.
                </>}
              </p>
            </>
          ) : null}
        </section>
      </div>

      {stuck.length > 0 ? (
        <section className={`${panel} mb-7`} aria-labelledby="t-parados">
          <div className="mb-3 flex items-baseline justify-between gap-3">
            <div>
              <h2 id="t-parados" className="text-[15px] font-semibold text-ink">Parados há mais tempo</h2>
              <p className="text-[12.5px] text-muted">Contratos além do prazo da etapa, os mais antigos primeiro</p>
            </div>
            <Link href="/app/propostas?atrasado=1" className="shrink-0 text-[13px] font-medium text-brand hover:underline">Ver todos</Link>
          </div>
          <ul>{stuck.map(c => (
            <li key={c.id}>
              <Link href={`/app/propostas/${c.proposal_id}`} className="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-4 gap-y-0.5 border-t border-line py-2.5 hover:bg-surface-muted sm:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)_auto_auto]">
                <span className="truncate text-sm text-ink">{c.full_name ?? 'Cliente sem nome'}</span>
                <span className="order-3 truncate text-[12.5px] text-muted sm:order-none">{[STATE_LABEL[c.canonical_state] ?? c.canonical_state, c.bank, c.seller_name].filter(Boolean).join(', ')}</span>
                <span className="text-right text-sm text-ink"><Money v={amountOf(c)} /></span>
                <span className="order-4 text-right text-[12.5px] font-medium text-[#B42318] sm:order-none">{plural(daysIn(c), 'dia', 'dias')} na etapa</span>
              </Link>
            </li>
          ))}</ul>
        </section>
      ) : null}

      <section className={`${panel} mb-7`} aria-labelledby="t-producao">
        <h2 id="t-producao" className="text-[15px] font-semibold text-ink">Produção paga por {board.period.by_month ? 'mês' : 'dia'}</h2>
        <p className="mb-4 text-[12.5px] text-muted">Toque em uma barra para ver os contratos daquele {board.period.by_month ? 'mês' : 'dia'}</p>
        {cur.contracts === 0 ? <p className="text-sm text-muted">Nenhum contrato pago ao cliente neste período.</p> : (
          <>
            <div className="flex h-44 items-end gap-0.5 border-b border-line-strong sm:gap-1.5" role="img" aria-label="Produção paga por período">
              {series.map(s => (
                <Link key={s.day} href={board.period.by_month ? paidLink() : paidLink({ pago_de: s.day, pago_ate: s.day })} title={`${dayLabel(s.day, board.period.by_month)}: ${money(s.production)}, ${plural(s.contracts, 'contrato', 'contratos')}`}
                  className="group flex h-full min-w-0 flex-1 flex-col items-center justify-end">
                  <span className={`block w-full max-w-10 rounded-t-[2px] ${s.contracts ? 'bg-brand/75 group-hover:bg-brand' : ''}`} style={{ height: s.contracts ? `${pct(s.production, maxDay)}%` : '0' }} />
                </Link>
              ))}
            </div>
            <div className="mt-1.5 flex gap-0.5 text-[11px] text-muted sm:gap-1.5">{series.map((s, i) => <span key={s.day} className="num min-w-0 flex-1 truncate text-center">{series.length <= 12 || i % Math.ceil(series.length / 8) === 0 ? dayLabel(s.day, board.period.by_month) : ''}</span>)}</div>
          </>
        )}
      </section>

      <div className="grid gap-6 xl:grid-cols-2">
        <section className={panel} aria-labelledby="t-vendedores">
          <h2 id="t-vendedores" className="mb-3 text-[15px] font-semibold text-ink">Vendedores no período</h2>
          {board.sellers.length === 0 ? <p className="text-sm text-muted">Sem produção paga neste período.</p> : (
            <table className="w-full border-collapse text-[13.5px] text-ink">
              <thead><tr className="text-[12px] text-muted"><th className="pb-1.5 text-left font-medium">Vendedor</th><th className="pb-1.5 text-right font-medium">Produção</th><th className="pb-1.5 text-right font-medium">Recebe</th></tr></thead>
              <tbody>{board.sellers.map(s => (
                <tr key={s.id ?? 'none'}>
                  <td className="border-b border-line py-2 pr-3"><Link href={paidLink({ vendedor: s.id ?? 'none' })} className={rowLink}>{s.name}</Link> <span className="text-[12px] text-muted">{plural(s.contracts, 'contrato', 'contratos')}</span></td>
                  <td className="border-b border-line py-2 text-right"><Money v={s.production} round /></td>
                  <td className="border-b border-line py-2 text-right text-ink-soft"><Money v={s.payable} /></td>
                </tr>
              ))}</tbody>
            </table>
          )}
        </section>
        <section className={panel} aria-labelledby="t-bancos">
          <h2 id="t-bancos" className="mb-3 text-[15px] font-semibold text-ink">Bancos no período</h2>
          {board.banks.length === 0 ? <p className="text-sm text-muted">Sem produção paga neste período.</p> : (
            <table className="w-full border-collapse text-[13.5px] text-ink">
              <thead><tr className="text-[12px] text-muted"><th className="pb-1.5 text-left font-medium">Banco</th><th className="pb-1.5 text-right font-medium">Produção</th><th className="pb-1.5 text-right font-medium">Comissão</th><th className="pb-1.5 text-right font-medium">Falta receber</th></tr></thead>
              <tbody>{board.banks.map(b => (
                <tr key={b.id ?? 'none'}>
                  <td className="border-b border-line py-2 pr-3"><Link href={paidLink({ banco: b.id ?? 'none' })} className={rowLink}>{b.name}</Link> <span className="text-[12px] text-muted">{plural(b.contracts, 'contrato', 'contratos')}</span></td>
                  <td className="border-b border-line py-2 text-right"><Money v={b.production} round /></td>
                  <td className="border-b border-line py-2 text-right text-ink-soft"><Money v={b.expected} /></td>
                  <td className={`border-b border-line py-2 text-right ${cmp(R(b.missing), ZERO) > 0 ? 'text-[#92400E]' : 'text-muted'}`}>{cmp(R(b.missing), ZERO) > 0 ? <Money v={b.missing} /> : 'nada'}</td>
                </tr>
              ))}</tbody>
            </table>
          )}
        </section>
      </div>
      <p className="mt-6 text-xs text-muted">Calculado na hora a partir dos contratos, recebimentos e repasses do Corban. Toque em qualquer número para ver os contratos por trás dele.</p>
    </section>
  )
}
