import Link from 'next/link'
import { AlertTriangle, ArrowDownRight, ArrowUpRight, ChevronRight } from 'lucide-react'
import { Card, CardHeader, PageHeader } from '@/components/ui'
import { cmp, div, fromDecimalString, isZero, mul, sub, toDecimalString, type Rational } from '@/lib/commission/money'
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
  if (key === 'hoje') return { from: iso(today), to: iso(today), prevFrom: iso(shift(today, -1)), prevTo: iso(shift(today, -1)), label: 'ontem' }
  if (key === '7d') return { from: iso(shift(today, -6)), to: iso(today), prevFrom: iso(shift(today, -13)), prevTo: iso(shift(today, -7)), label: '7 dias anteriores' }
  if (key === 'ano') return { from: iso(utc(y, 0, 1)), to: iso(today), prevFrom: iso(utc(y - 1, 0, 1)), prevTo: iso(utc(y - 1, m - 1, Math.min(d, new Date(Date.UTC(y - 1, m, 0)).getUTCDate()))), label: 'mesmo período do ano passado' }
  const lastPrev = new Date(Date.UTC(y, m - 1, 0)).getUTCDate()
  return { from: iso(utc(y, m - 1, 1)), to: iso(today), prevFrom: iso(utc(y, m - 2, 1)), prevTo: iso(utc(y, m - 2, Math.min(d, lastPrev))), label: 'mesmos dias do mês passado' }
}

const R = (v: number | string | null | undefined) => fromDecimalString(String(v ?? 0))
const money = (v: number | string) => brlText(toDecimalString(R(v), 2))
// "R$ 412,3 mil" for the big numbers; exact cents stay in the lists.
function short(v: number | string): string {
  const r = R(v)
  const abs = cmp(r, R(0)) < 0 ? sub(R(0), r) : r
  if (cmp(abs, R(1_000_000)) >= 0) return `R$ ${toDecimalString(div(r, R(1_000_000)), 1).replace('.', ',')} mi`
  if (cmp(abs, R(10_000)) >= 0) return `R$ ${toDecimalString(div(r, R(1_000)), 1).replace('.', ',')} mil`
  return money(v)
}
function change(cur: number, prev: number): { text: string; up: boolean } | null {
  const p = R(prev)
  if (isZero(p)) return null
  const pct = mul(div(sub(R(cur), p), p), R(100))
  const up = cmp(pct, R(0)) >= 0
  return { text: `${up ? '+' : ''}${toDecimalString(pct, 0)}%`, up }
}
const dayLabel = (d: string, byMonth: boolean) => {
  const [y, m, day] = d.split('-')
  return byMonth ? ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'][Number(m) - 1] + `/${y.slice(2)}` : `${day}/${m}`
}
const STATE_LABEL: Record<string, string> = {
  digitization_queue: 'Fila de digitação', digitizing: 'Digitando', submitted: 'No banco', pending_external: 'Pendência', approved: 'Aprovado',
}

// The owner's dashboard (06/10/2026, models A + D + B + E): the month in big numbers with the comparison, what needs
// attention first, production per day, sellers, banks and the pipeline. Every number opens the list behind it.
export async function OwnerDashboard({ supabase, organizationId, organizationName, period }: { supabase: Supa; organizationId: string; organizationName?: string; period: PeriodKey }) {
  const range = periodRange(period)
  const { data, error } = await supabase.rpc('owner_dashboard', { p_org: organizationId, p_from: range.from, p_to: range.to, p_prev_from: range.prevFrom, p_prev_to: range.prevTo })
  const board = data as Board | null
  const paidLink = (extra: Record<string, string> = {}) => `/app/contratos?${new URLSearchParams({ situacao: 'paid', pago_de: range.from, pago_ate: range.to, n: '100', ...extra })}`

  const header = (
    <PageHeader title="Visão geral" description={organizationName}
      actions={<nav aria-label="Período" className="flex gap-1 rounded-[12px] border border-line bg-surface p-1">
        {(Object.keys(PERIODS) as PeriodKey[]).map(k => (
          <Link key={k} href={`/app?periodo=${k}`} aria-current={k === period ? 'page' : undefined}
            className={`rounded-[9px] px-3 py-1.5 text-sm ${k === period ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted'}`}>{PERIODS[k]}</Link>
        ))}
      </nav>} />
  )
  if (error || !board) return <section>{header}<Card className="p-5 text-sm text-[#92400E]">Não foi possível carregar os números agora. Tente de novo em instantes.</Card></section>

  const { current: cur, previous: prev, attention: at } = board
  const kpis: { label: string; value: number; prev: number; href: string; hint: string }[] = [
    { label: 'Produção paga', value: cur.production, prev: prev.production, href: paidLink(), hint: `${cur.contracts} contrato(s) pagos ao cliente` },
    { label: 'Comissão prevista', value: cur.expected, prev: prev.expected, href: paidLink(), hint: 'o que os bancos pagam por esses contratos' },
    { label: 'Recebido dos bancos', value: cur.received, prev: prev.received, href: '/app/financeiro/conciliacao', hint: 'comissão que entrou no período' },
    { label: 'Fica na empresa', value: cur.margin, prev: prev.margin, href: paidLink(), hint: `depois de imposto e de ${short(cur.sellers)} aos vendedores` },
  ]
  const alerts = [
    { n: at.bank_late.n, label: 'Banco não pagou há mais de 30 dias', value: at.bank_late.amount, href: '/app/contratos?repasse=banco&n=100', tone: 'danger' },
    { n: at.divergent.n, label: 'Comissão do banco diferente do previsto', value: null, href: '/app/contratos?repasse=divergente&n=100', tone: 'warn' },
    { n: at.to_pay.n, label: 'Vendedores com repasse a pagar', value: at.to_pay.amount, href: '/app/repasse#pagar', tone: 'warn' },
    { n: at.stale.n, label: 'Comissões desatualizadas (vendedor ou grupo mudou)', value: null, href: '/app/contratos?desatualizado=1&n=100', tone: 'warn' },
    { n: at.no_calc.n, label: 'Contratos pagos sem comissão calculada', value: null, href: '/app/contratos?comissao=pendente&situacao=paid&n=100', tone: 'warn' },
    { n: at.overdue.n, label: 'Contratos parados além do prazo da etapa', value: null, href: '/app/operacao', tone: 'warn' },
  ].filter(a => a.n > 0)
  // Every day (or month) of the period, the empty ones too, so the gaps show.
  const byDay = new Map(board.series.map(s => [s.day, s]))
  const slots: string[] = []
  for (let d = new Date(`${board.period.from}T12:00:00Z`); iso(d) <= board.period.to; d = board.period.by_month ? new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1, 12)) : new Date(d.getTime() + 86_400_000))
    slots.push(board.period.by_month ? iso(d).slice(0, 8) + '01' : iso(d))
  board.series = slots.map(day => byDay.get(day) ?? { day, production: 0, contracts: 0 })
  const maxDay = board.series.reduce((m, s) => (cmp(R(s.production), m) > 0 ? R(s.production) : m), R(0))
  const maxSeller = board.sellers.reduce((m, s) => (cmp(R(s.production), m) > 0 ? R(s.production) : m), R(0))
  const pct = (v: number, max: Rational) => (isZero(max) ? 0 : Math.max(2, Number(toDecimalString(mul(div(R(v), max), R(100)), 0))))
  const pipeline = Object.entries(board.pipeline).sort((a, b) => Object.keys(STATE_LABEL).indexOf(a[0]) - Object.keys(STATE_LABEL).indexOf(b[0]))

  return (
    <section>
      {header}
      <p className="-mt-2 mb-4 text-xs text-muted">Comparado com {range.label}. Toque em qualquer número para ver os contratos.</p>

      <div className="mb-4 grid grid-cols-2 gap-3 xl:grid-cols-4">
        {kpis.map(k => {
          const c = change(k.value, k.prev)
          return (
            <Link key={k.label} href={k.href} className="flex flex-col gap-1 rounded-[14px] border border-line bg-surface px-5 py-4 hover:border-line-strong hover:bg-surface-muted">
              <span className="text-[13px] font-medium text-muted">{k.label}</span>
              <span className="num text-xl font-semibold tracking-tight text-ink sm:text-[26px]">{short(k.value)}</span>
              <span className="flex flex-wrap items-center gap-1.5 text-xs">
                {c ? <span className={`inline-flex items-center gap-0.5 font-medium ${c.up ? 'text-[#166534]' : 'text-[#B91C1C]'}`}>{c.up ? <ArrowUpRight size={13} aria-hidden /> : <ArrowDownRight size={13} aria-hidden />}{c.text}</span>
                  : <span className="text-muted">sem base para comparar</span>}
                <span className="text-ink-soft">{k.hint}</span>
              </span>
            </Link>
          )
        })}
      </div>

      <Card className="mb-4">
        <CardHeader title={<span className="flex items-center gap-2"><AlertTriangle size={16} aria-hidden className={alerts.length ? 'text-[#B45309]' : 'text-muted'} />Precisa da sua atenção</span>} />
        {alerts.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nada fora do normal agora.</p> : (
          <ul className="mt-2">{alerts.map(a => (
            <li key={a.label}><Link href={a.href} className="flex items-center justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
              <span className="text-sm text-ink">{a.label}</span>
              <span className="flex items-center gap-3"><span className="num whitespace-nowrap text-sm text-ink-soft">{a.value !== null ? money(a.value) : ''}</span>
                <strong className={`num min-w-8 text-right text-lg ${a.tone === 'danger' ? 'text-[#B91C1C]' : 'text-[#92400E]'}`}>{a.n}</strong><ChevronRight size={16} aria-hidden className="text-muted" /></span>
            </Link></li>
          ))}</ul>
        )}
      </Card>

      <div className="mb-4 grid gap-4 xl:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
        <Card>
          <CardHeader title={`Produção paga por ${board.period.by_month ? 'mês' : 'dia'}`} />
          {board.series.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhum contrato pago ao cliente neste período.</p> : (
            <div className="px-5 pb-5 pt-3">
              <div className="flex h-44 items-end gap-0.5 sm:gap-1.5" role="img" aria-label="Produção paga por período">
                {board.series.map(s => (
                  <Link key={s.day} href={board.period.by_month ? paidLink() : paidLink({ pago_de: s.day, pago_ate: s.day })} title={`${dayLabel(s.day, board.period.by_month)}: ${money(s.production)} · ${s.contracts} contrato(s)`}
                    className="group flex h-full min-w-0 flex-1 flex-col justify-end">
                    <span className={`block rounded-t-[4px] ${s.contracts ? 'bg-brand/80 group-hover:bg-brand' : 'bg-line'}`} style={{ height: s.contracts ? `${pct(s.production, maxDay)}%` : '2px' }} />
                  </Link>
                ))}
              </div>
              <div className="mt-1.5 flex gap-0.5 text-[11px] text-muted sm:gap-1.5">{board.series.map((s, i) => <span key={s.day} className="min-w-0 flex-1 truncate text-center">{board.series.length <= 12 || i % Math.ceil(board.series.length / 8) === 0 ? dayLabel(s.day, board.period.by_month) : ''}</span>)}</div>
            </div>
          )}
        </Card>
        <Card>
          <CardHeader title="Vendedores · produção paga" />
          {board.sellers.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Sem produção paga neste período.</p> : (
            <ul className="px-5 pb-4 pt-2">{board.sellers.map((s, i) => (
              <li key={s.id ?? 'none'}><Link href={s.id ? paidLink({ vendedor: s.id }) : paidLink()} className="block rounded-md py-1.5 hover:bg-surface-muted">
                <span className="flex items-baseline justify-between gap-2 text-[13px]"><span className="truncate text-ink"><span className="mr-1.5 text-muted">{i + 1}</span>{s.name}</span><span className="num shrink-0 font-medium text-ink">{short(s.production)}</span></span>
                <span className="mt-1 block h-1.5 rounded-full bg-surface-muted"><span className="block h-1.5 rounded-full bg-[#1D9E75]" style={{ width: `${pct(s.production, maxSeller)}%` }} /></span>
                <span className="mt-0.5 block text-[11px] text-muted">{s.contracts} contrato(s) · recebe {money(s.payable)}</span>
              </Link></li>
            ))}</ul>
          )}
        </Card>
      </div>

      <Card className="mb-4">
        <CardHeader title="Por banco" />
        {board.banks.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Sem produção paga neste período.</p> : (
          <div className="grid gap-3 px-5 pb-5 pt-3 sm:grid-cols-2 xl:grid-cols-3">{board.banks.map(b => (
            <Link key={b.id ?? 'none'} href={b.id ? paidLink({ banco: b.id }) : paidLink()} className="rounded-[12px] border border-line p-4 hover:border-line-strong hover:bg-surface-muted">
              <span className="block text-sm font-semibold text-ink">{b.name}</span>
              <span className="num mt-1 block text-xl font-semibold text-ink">{short(b.production)}</span>
              <span className="mt-2 grid gap-1 text-[13px]">
                <span className="flex justify-between"><span className="text-ink-soft">Contratos</span><span className="num">{b.contracts}</span></span>
                <span className="flex justify-between"><span className="text-ink-soft">Ticket médio</span><span className="num">{b.contracts ? short(toDecimalString(div(R(b.production), R(b.contracts)), 2)) : '—'}</span></span>
                <span className="flex justify-between"><span className="text-ink-soft">Comissão prevista</span><span className="num">{money(b.expected)}</span></span>
                <span className="flex justify-between"><span className="text-ink-soft">Falta receber</span><span className={`num ${cmp(R(b.missing), R(0)) > 0 ? 'text-[#92400E]' : 'text-[#166534]'}`}>{money(b.missing)}</span></span>
              </span>
            </Link>
          ))}</div>
        )}
      </Card>

      <Card>
        <CardHeader title="Esteira agora" />
        <div className="flex flex-wrap gap-2 px-5 pb-5 pt-3">
          {pipeline.length === 0 ? <span className="text-sm text-muted">Nenhum contrato em andamento.</span> : pipeline.map(([state, n]) => (
            <Link key={state} href="/app/operacao" className={`rounded-[10px] border px-3 py-2 text-sm hover:bg-surface-muted ${state === 'pending_external' ? 'border-[#FCD34D] bg-[#FFFBEB] text-[#92400E]' : 'border-line text-ink'}`}>
              {STATE_LABEL[state] ?? state} <strong className="num ml-1">{n}</strong>
            </Link>
          ))}
        </div>
      </Card>
      <p className="mt-6 text-xs text-muted">Números da sua empresa, calculados na hora a partir dos contratos, recebimentos e repasses do Corban.</p>
    </section>
  )
}
