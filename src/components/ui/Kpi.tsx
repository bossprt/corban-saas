import type { ReactNode } from 'react'
import Link from 'next/link'

// Headline number card for dashboards. `value` arrives already formatted (money is formatted from exact decimals, never floats).
// With `href` the whole card opens the full list behind the number.
export function Kpi({ label, value, hint, href }: { label: string; value: ReactNode; hint?: ReactNode; href?: string }) {
  const body = (
    <>
      <span className="narrow text-[13px] text-muted">{label}</span>
      <span className="num wide text-[28px] font-extrabold text-ink">{value}</span>
      {hint ? <span className="text-[13px] text-ink-soft">{hint}</span> : null}
    </>
  )
  return href
    ? <Link href={href} className="group flex flex-col gap-1.5 border-t-[3px] border-ink bg-surface py-3 hover:bg-surface-muted">{body}</Link>
    : <div className="flex flex-col gap-1.5 border-t-[3px] border-ink bg-surface py-3">{body}</div>
}
