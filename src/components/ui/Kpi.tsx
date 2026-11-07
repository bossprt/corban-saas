import type { ReactNode } from 'react'
import Link from 'next/link'

// Headline number card for dashboards. `value` arrives already formatted (money is formatted from exact decimals, never floats).
// With `href` the whole card opens the full list behind the number.
export function Kpi({ label, value, hint, href }: { label: string; value: ReactNode; hint?: ReactNode; href?: string }) {
  const body = (
    <>
      <span className="text-[13px] font-medium text-muted">{label}</span>
      <span className="num text-[28px] font-semibold tracking-tight text-ink">{value}</span>
      {hint ? <span className="text-[13px] text-ink-soft">{hint}</span> : null}
    </>
  )
  return href
    ? <Link href={href} className="group flex flex-col gap-1.5 rounded-[14px] border border-line bg-surface px-5 py-4 hover:border-brand hover:bg-surface-muted">{body}</Link>
    : <div className="flex flex-col gap-1.5 rounded-[14px] border border-line bg-surface px-5 py-4">{body}</div>
}
