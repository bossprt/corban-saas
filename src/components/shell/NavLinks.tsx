'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useState, type ReactNode } from 'react'
import { cn } from '@/components/ui'

export type NavKey = 'hoje' | 'dashboard' | 'clientes' | 'vendas' | 'esteira' | 'contratos' | 'metas' | 'financeiro' | 'repasse' | 'comercial' | 'relatorios' | 'configuracoes' | 'portal' | 'portal_nova'
export type NavLink = { href: string; label: string }
// `children` open under the item while the user is in one of its `sections` (Cadastros lists every registration).
export type NavItem = { key: NavKey; href: string; label: string; children?: NavLink[]; sections?: string[] }

// Text-only menu (identity "Boleto ipê", owner 07/11/2026): no icon per item; the current page is marked in ipê yellow.

// '/app' is the dashboard; every other item is active on its own prefix.
function isActive(pathname: string, href: string) {
  return href === '/app' ? pathname === '/app' : pathname === href || pathname.startsWith(`${href}/`)
}

export function SideNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname()
  return (
    <nav aria-label="Principal" className="flex flex-col gap-0.5">
      {items.map(({ key, href, label, children, sections }) => {
        const inSection = isActive(pathname, href) || (sections ?? []).some(s => isActive(pathname, s))
        const childActive = (children ?? []).some(c => isActive(pathname, c.href))
        const active = inSection && !childActive
        return (
          <div key={key}>
            <Link
              href={href}
              aria-current={active ? 'page' : undefined}
              aria-expanded={children ? inSection : undefined}
              className={cn(
                'narrow flex items-center px-2 py-1.5 text-[16px] font-semibold text-ink',
                active ? 'bg-highlight font-extrabold' : inSection ? 'font-extrabold' : 'hover:underline underline-offset-4',
              )}
            >
              {label}
            </Link>
            {children && inSection && (
              <ul className="mb-2 ml-2 mt-0.5 flex flex-col border-l-2 border-ink pl-2">
                {children.map(c => {
                  // Only the most specific child is marked (/app/financeiro vs /app/financeiro/empresa).
                  const on = isActive(pathname, c.href) && !children.some(o => o.href.length > c.href.length && isActive(pathname, o.href))
                  return (
                    <li key={c.href}>
                      <Link href={c.href} aria-current={on ? 'page' : undefined}
                        className={cn('block px-2 py-1 text-[14px] text-ink', on ? 'bg-highlight font-bold' : 'hover:underline underline-offset-4')}>
                        {c.label}
                      </Link>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        )
      })}
    </nav>
  )
}

// Phone navigation: the most used destinations and "Mais", which opens the whole menu (every item, its sub-pages and Sair).
// Order of preference (owner, 06/11/2026): Hoje · Esteira · Contratos · Repasse; Vendas and Clientes only fill a slot left by a module that is off.
const PHONE_MAIN: NavKey[] = ['portal', 'portal_nova', 'hoje', 'esteira', 'contratos', 'repasse', 'vendas', 'clientes']
export function BottomNav({ items, footer }: { items: NavItem[]; footer?: ReactNode }) {
  const pathname = usePathname()
  const [open, setOpen] = useState(false)
  const [at, setAt] = useState(pathname)
  // Close the menu after navigating (state reset on path change, no effect needed).
  if (at !== pathname) { setAt(pathname); setOpen(false) }
  const main = items.filter(i => PHONE_MAIN.includes(i.key)).sort((x, y) => PHONE_MAIN.indexOf(x.key) - PHONE_MAIN.indexOf(y.key)).slice(0, 4)
  const hasMore = items.some(i => !main.includes(i)) || !!footer
  const cols = main.length + (hasMore ? 1 : 0)
  return (
    <>
      {open && (
        <div role="dialog" aria-modal="true" aria-label="Menu" className="fixed inset-0 z-40 flex flex-col bg-canvas md:hidden">
          <div className="flex h-14 items-center justify-between border-b-4 border-ink px-4">
            <span className="wide text-lg font-extrabold text-ink">Menu</span>
            <button type="button" onClick={() => setOpen(false)} className="border-2 border-ink bg-highlight px-3 py-1 text-sm font-extrabold text-ink">Fechar</button>
          </div>
          <div className="flex-1 overflow-y-auto px-3 py-3">
            <nav aria-label="Menu completo" className="flex flex-col gap-0.5">
              {items.map(({ key, href, label, children }) => {
                return (
                  <div key={key}>
                    <Link href={href} onClick={() => setOpen(false)} aria-current={isActive(pathname, href) ? 'page' : undefined}
                      className={cn('narrow flex min-h-12 items-center px-3 text-[19px] font-semibold text-ink', isActive(pathname, href) && 'bg-highlight font-extrabold')}>
                      {label}
                    </Link>
                    {children && (
                      <ul className="mb-1 ml-3 flex flex-col border-l-2 border-ink pl-3">
                        {children.map(c => (
                          <li key={c.href}><Link href={c.href} onClick={() => setOpen(false)} className="flex min-h-11 items-center text-[15px] text-ink">{c.label}</Link></li>
                        ))}
                      </ul>
                    )}
                  </div>
                )
              })}
            </nav>
            {footer && <div className="mt-4 border-t-4 border-ink px-3 pt-4">{footer}</div>}
          </div>
        </div>
      )}
      <nav aria-label="Navegação inferior" className="fixed inset-x-0 bottom-0 z-30 grid border-t-4 border-ink bg-surface pb-[env(safe-area-inset-bottom)] md:hidden" style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}>
        {main.map(({ key, href, label }) => {
          const active = isActive(pathname, href)
          return (
            <Link key={key} href={href} aria-current={active ? 'page' : undefined} className={cn('narrow flex min-h-14 items-center justify-center px-1 text-center text-[14px] font-bold text-ink', active && 'bg-highlight font-extrabold')}>
              {label}
            </Link>
          )
        })}
        {hasMore && (
          <button type="button" onClick={() => setOpen(true)} aria-expanded={open} className="narrow flex min-h-14 items-center justify-center border-l-2 border-ink text-[14px] font-bold text-ink">
            Mais
          </button>
        )}
      </nav>
    </>
  )
}
