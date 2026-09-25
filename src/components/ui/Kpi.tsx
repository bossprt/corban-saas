import type { ReactNode } from 'react'

// Headline number card for dashboards. `value` arrives already formatted (money is formatted from exact decimals, never floats).
export function Kpi({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5 rounded-[14px] border border-line bg-surface px-5 py-4">
      <span className="text-[13px] font-medium text-muted">{label}</span>
      <span className="num text-[28px] font-semibold tracking-tight text-ink">{value}</span>
      {hint ? <span className="text-[13px] text-ink-soft">{hint}</span> : null}
    </div>
  )
}
