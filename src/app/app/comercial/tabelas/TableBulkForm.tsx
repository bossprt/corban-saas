'use client'
import { useRef, useState, type ReactNode } from 'react'

// The result list as one form (owner request 13/11/2026): mark tables and deactivate (or reactivate) them at once.
// The count and "mark all on this page" only read the checkboxes; the server action checks everything again.
export function TableBulkForm({ action, back, reactivate, children }: { action: (f: FormData) => Promise<void>; back: string; reactivate: boolean; children: ReactNode }) {
  const ref = useRef<HTMLFormElement>(null)
  const [count, setCount] = useState(0)
  const boxes = () => [...(ref.current?.querySelectorAll<HTMLInputElement>('input[name="table_id"]') ?? [])]
  const recount = () => setCount(boxes().filter(b => b.checked).length)
  const label = reactivate ? 'Reativar' : 'Desativar'
  return <form ref={ref} method="post" action={action} onChange={recount}
    onSubmit={e => { if (!count || (!reactivate && !window.confirm(`Desativar ${count} tabela(s)? Elas deixam de aparecer para novas propostas.`))) e.preventDefault() }}>
    <input type="hidden" name="back" value={back} />
    <input type="hidden" name="status" value={reactivate ? 'active' : 'archived'} />
    <div className={`mx-5 mt-3 flex flex-wrap items-center justify-between gap-3 rounded-[10px] px-4 py-2 ${count ? 'bg-brand-soft' : 'bg-surface-muted'}`}>
      <label className="flex items-center gap-2 text-[13px] text-ink-soft"><input type="checkbox" aria-label="Marcar todas desta página" className="accent-[var(--brand)]"
        onChange={e => { for (const b of boxes()) b.checked = e.target.checked; recount() }} />Marcar todas desta página</label>
      <span className="flex items-center gap-2 text-[13px]"><strong className="text-ink">{count} marcada(s)</strong>
        <button disabled={!count} className={`h-9 rounded-[10px] border px-3 text-sm font-semibold disabled:opacity-40 ${reactivate ? 'border-line-strong bg-surface text-ink' : 'border-[#F3B4B4] bg-surface text-[#B42318]'}`}>{label} {count || ''} tabela(s)</button></span>
    </div>
    {children}
  </form>
}
