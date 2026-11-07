import Link from 'next/link'
import type { ReactNode } from 'react'

// Server-rendered SVG charts for the owner's dashboard (visual "cores da empresa", 07/11/2026). No chart library.
// Values arrive as numbers ONLY for drawing (pixel geometry); every amount shown as text is formatted by the caller
// from exact decimals, never from these numbers.

// Categorical colors derived from the company colors (globals.css --chart-*), one per bank or pipeline stage.
export const SERIES = ['var(--chart-1)', 'var(--chart-2)', 'var(--chart-3)', 'var(--chart-4)', 'var(--chart-5)']

// Production of the period: cumulative line with a soft area, plus one light bar per day (or month) that opens its contracts.
export function ProductionChart({ points, axisLabel, lastLabel }: {
  points: { label: string; value: number; href: string; title: string }[]
  axisLabel: (v: number) => string
  lastLabel: string
}) {
  const W = 720, H = 240, L = 52, R = 16, T = 26, B = 28
  const n = points.length
  const cumulative = points.map((_, i) => points.slice(0, i + 1).reduce((a, p) => a + p.value, 0))
  const top = Math.max(1, ...cumulative)
  const step = niceStep(top / 4)
  const max = step * Math.ceil(top / step)
  const x = (i: number) => L + (n === 1 ? (W - L - R) / 2 : (i * (W - L - R)) / (n - 1))
  const y = (v: number) => T + (H - T - B) * (1 - v / max)
  const barW = Math.max(3, Math.min(26, ((W - L - R) / Math.max(1, n)) * 0.45))
  const line = cumulative.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' ')
  const area = `${line} L${x(n - 1).toFixed(1)},${y(0)} L${x(0).toFixed(1)},${y(0)} Z`
  const ticks = Array.from({ length: Math.round(max / step) + 1 }, (_, i) => i * step)
  const every = Math.ceil(n / 10)
  const lx = x(n - 1), ly = y(cumulative[n - 1] ?? 0)
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Produção paga acumulada no período">
      <defs>
        <linearGradient id="prod-fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--brand)" stopOpacity="0.22" />
          <stop offset="100%" stopColor="var(--brand)" stopOpacity="0.02" />
        </linearGradient>
      </defs>
      {ticks.map(t => (
        <g key={t}>
          <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} stroke="var(--line)" strokeWidth="1" />
          <text x={L - 8} y={y(t) + 4} textAnchor="end" fontSize="11" fill="var(--muted)">{axisLabel(t)}</text>
        </g>
      ))}
      {points.map((p, i) => {
        const h = (H - T - B) * (p.value / max)
        return (
          <Link key={p.label + i} href={p.href}>
            <title>{p.title}</title>
            <rect x={x(i) - barW / 2} y={y(0) - h} width={barW} height={Math.max(0, h)} rx="2" fill="var(--chart-3)" opacity="0.45" />
            <rect x={x(i) - 14} y={T} width="28" height={H - T - B} fill="transparent" />
          </Link>
        )
      })}
      <path d={area} fill="url(#prod-fill)" />
      <path d={line} fill="none" stroke="var(--brand)" strokeWidth="2.5" strokeLinejoin="round" />
      {n <= 31 ? cumulative.map((v, i) => <circle key={i} cx={x(i)} cy={y(v)} r="3" fill="white" stroke="var(--brand)" strokeWidth="1.8" />) : null}
      <circle cx={lx} cy={ly} r="5.5" fill="var(--brand)" stroke="white" strokeWidth="2" />
      <g transform={`translate(${Math.min(Math.max(lx, L + 60), W - R - 60)},${Math.max(ly - 16, 12)})`}>
        <rect x="-60" y="-12" width="120" height="22" rx="5" fill="var(--ink)" />
        <text y="3.5" textAnchor="middle" fontSize="11.5" fontWeight="700" fill="white">{lastLabel}</text>
      </g>
      {points.map((p, i) => (i % every === 0 || i === n - 1) ? (
        <text key={'l' + i} x={x(i)} y={H - 8} textAnchor="middle" fontSize="11" fill={i === n - 1 ? 'var(--ink)' : 'var(--muted)'} fontWeight={i === n - 1 ? 700 : 400}>{p.label}</text>
      ) : null)}
    </svg>
  )
}

function niceStep(raw: number) {
  if (raw <= 0) return 1
  const p = 10 ** Math.floor(Math.log10(raw))
  const f = raw / p
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p
}

// Donut: share of each item, the total in the middle.
export function Donut({ items, center, sub }: { items: { value: number; color: string }[]; center: ReactNode; sub: string }) {
  const total = items.reduce((s, i) => s + i.value, 0)
  const r = 70, c = 2 * Math.PI * r
  const lens = items.map(it => (total ? (it.value / total) * c : 0))
  const offsets = lens.map((_, i) => lens.slice(0, i).reduce((a, b) => a + b, 0))
  return (
    <div className="relative mx-auto aspect-square w-full max-w-[210px]">
      <svg viewBox="0 0 180 180" className="h-full w-full -rotate-90" aria-hidden>
        <circle cx="90" cy="90" r={r} fill="none" stroke="var(--line)" strokeWidth="22" />
        {total > 0 ? items.map((it, i) => (
          <circle key={i} cx="90" cy="90" r={r} fill="none" stroke={it.color} strokeWidth="22" strokeDasharray={`${Math.max(0, lens[i] - 2)} ${c}`} strokeDashoffset={-offsets[i]} />
        )) : null}
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
        <span className="text-[17px] font-extrabold tracking-tight text-ink">{center}</span>
        <span className="text-[12px] text-muted">{sub}</span>
      </div>
    </div>
  )
}

// Half gauge: received of the expected commission, split by bank.
export function Gauge({ pct, parts }: { pct: number; parts: { value: number; color: string }[] }) {
  const r = 80, half = Math.PI * r
  const total = parts.reduce((s, p) => s + p.value, 0)
  const filled = (Math.min(100, Math.max(0, pct)) / 100) * half
  const lens = parts.map(p => (total ? (p.value / total) * filled : 0))
  const offsets = lens.map((_, i) => lens.slice(0, i).reduce((a, b) => a + b, 0))
  return (
    <div className="relative mx-auto w-full max-w-[240px]">
      <svg viewBox="0 0 200 112" className="h-auto w-full" aria-hidden>
        <path d="M20,100 A80,80 0 0 1 180,100" fill="none" stroke="var(--line)" strokeWidth="20" strokeLinecap="butt" />
        {total > 0 ? parts.map((p, i) => (
          <path key={i} d="M20,100 A80,80 0 0 1 180,100" fill="none" stroke={p.color} strokeWidth="20" strokeDasharray={`${Math.max(0, lens[i] - 1.5)} ${half * 2}`} strokeDashoffset={-offsets[i]} />
        )) : null}
      </svg>
      <div className="absolute inset-x-0 bottom-0 flex flex-col items-center">
        <span className="text-[30px] font-extrabold leading-none tracking-tight text-ink">{Math.round(pct)}%</span>
        <span className="mt-1 text-[12px] text-muted">da comissão prevista</span>
      </div>
    </div>
  )
}

// Horizontal waterfall: from the expected commission down to what stays in the company.
export function Waterfall({ steps }: { steps: { label: ReactNode; amount: ReactNode; value: number; kind: 'start' | 'minus' | 'total'; color: string; href?: string }[] }) {
  const start = steps.find(s => s.kind === 'start')?.value ?? 0
  const max = Math.max(1, start)
  // Each deduction hangs from the level the previous one left.
  const spans = steps.reduce<{ from: number; to: number; level: number }[]>((acc, s) => {
    const level = acc.length ? acc[acc.length - 1].level : start
    if (s.kind === 'minus') return [...acc, { from: level - s.value, to: level, level: level - s.value }]
    return [...acc, { from: 0, to: s.value, level }]
  }, [])
  return (
    <div className="flex flex-col">
      {steps.map((s, i) => {
        const { from, to } = spans[i]
        const left = (Math.max(0, from) / max) * 100
        const width = Math.max(0.8, ((Math.max(0, to) - Math.max(0, from)) / max) * 100)
        const row = (
          <div className={`grid grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)_128px] items-center gap-3 sm:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)_150px] rounded-md px-2 py-2.5 sm:gap-4 ${s.kind === 'total' ? 'bg-brand-soft' : ''}`}>
            <span className={`flex items-center gap-2 text-[13.5px] ${s.kind === 'total' ? 'font-extrabold text-ink' : 'text-ink-soft'}`}>
              <i className="size-2.5 shrink-0 rounded-[2px]" style={{ background: s.color }} />{s.label}
            </span>
            <span className="relative block h-5" aria-hidden>
              <span className="absolute inset-y-0 rounded-[3px]" style={{ left: `${left}%`, width: `${width}%`, background: s.color }} />
            </span>
            <span className={`text-right ${s.kind === 'total' ? 'text-[20px] font-extrabold text-brand-strong' : 'text-[13.5px] font-bold text-ink'}`}>{s.amount}</span>
          </div>
        )
        return s.href ? <Link key={i} href={s.href} className="rounded-md hover:bg-surface-muted">{row}</Link> : <div key={i}>{row}</div>
      })}
    </div>
  )
}

// One stacked bar: the share of each item (pipeline stages by number of contracts).
export function StackBar({ items }: { items: { value: number; color: string; label: string; href?: string }[] }) {
  const total = items.reduce((s, i) => s + i.value, 0)
  if (!total) return null
  return (
    <div className="flex h-8 w-full overflow-hidden rounded-md" role="img" aria-label={items.map(i => `${i.label}: ${i.value}`).join(', ')}>
      {items.map(it => {
        const body = <span className="flex h-full items-center px-2 text-[12.5px] font-bold text-white" style={{ background: it.color }}>{it.value / total > 0.06 ? it.value : ''}</span>
        const style = { width: `${(it.value / total) * 100}%` }
        return it.href ? <Link key={it.label} href={it.href} style={style} title={`${it.label}: ${it.value}`} className="hover:opacity-90">{body}</Link> : <span key={it.label} style={style}>{body}</span>
      })}
    </div>
  )
}

// Thin share bar inside a table cell.
export function ShareBar({ pct }: { pct: number }) {
  return (
    <span className="block h-2 w-full overflow-hidden rounded-full bg-surface-muted ring-1 ring-line" aria-hidden>
      <span className="block h-full rounded-full bg-brand" style={{ width: `${Math.min(100, Math.max(1, pct))}%` }} />
    </span>
  )
}
