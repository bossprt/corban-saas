'use client'
import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { ChevronDown } from 'lucide-react'

export type RowMenuItem = { acao: string; label: string; href: string }

// The little arrow under the row's checkbox (owner, 08/10/2026): a short menu of quick changes; each one opens its window
// over the list, and closing it brings back the same list.
export function RowMenu({ label, items }: { label: string; items: RowMenuItem[] }) {
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const close = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false) }
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', close); document.addEventListener('keydown', esc)
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc) }
  }, [open])
  return (
    <div ref={box} className="relative mt-1">
      <button type="button" onClick={() => setOpen(o => !o)} aria-expanded={open} aria-haspopup="menu" aria-label={`Alterações rápidas: ${label}`}
        className={`inline-flex size-6 items-center justify-center rounded-md border text-white ${open ? 'border-brand-strong bg-brand-strong' : 'border-brand bg-brand hover:bg-brand-strong'}`}>
        <ChevronDown size={14} aria-hidden className={open ? 'rotate-180 transition-transform' : 'transition-transform'} />
      </button>
      {open && (
        <ul role="menu" className="absolute left-0 top-7 z-30 w-56 overflow-hidden rounded-[10px] border border-line bg-surface py-1 shadow-lg">
          {items.map(i => (
            <li key={i.acao} role="none">
              <Link role="menuitem" href={i.href} scroll={false} onClick={() => setOpen(false)} className="block px-3 py-2 text-sm text-ink hover:bg-surface-muted">{i.label}</Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
