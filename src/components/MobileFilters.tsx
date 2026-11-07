'use client'

import { useState, type ReactNode } from 'react'
import { SlidersHorizontal } from 'lucide-react'

// On the phone the optional filters stay behind a "Filtros" button, so the list starts near the top (audit 06/11/2026:
// Contratos began ~2,000 px down). From the sm breakpoint up the children sit in the parent grid as before.
export function MobileFilters({ active, children }: { active: number; children: ReactNode }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button type="button" onClick={() => setOpen(o => !o)} aria-expanded={open}
        className="inline-flex h-10 items-center justify-center gap-2 rounded-none border border-line bg-surface px-3 text-sm text-ink-soft hover:bg-surface-muted sm:hidden">
        <SlidersHorizontal size={15} aria-hidden />{open ? 'Esconder filtros' : 'Filtros'}{active > 0 && <span className="num rounded-full bg-brand-soft px-1.5 text-xs font-semibold text-brand">{active}</span>}
      </button>
      <div className={`${open ? 'grid gap-3' : 'hidden'} sm:contents`}>{children}</div>
    </>
  )
}
