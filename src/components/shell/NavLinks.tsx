'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useState, type ReactNode } from 'react'
import { BarChart3, CalendarCheck, FilePlus2, FileText, FolderOpen, HandCoins, Handshake, Home, KanbanSquare, LayoutDashboard, Menu, Settings, Target, Users, WalletCards, X, type LucideIcon } from 'lucide-react'
import { cn } from '@/components/ui'

export type NavKey = 'hoje' | 'dashboard' | 'clientes' | 'vendas' | 'esteira' | 'contratos' | 'metas' | 'financeiro' | 'repasse' | 'comercial' | 'relatorios' | 'configuracoes' | 'portal' | 'portal_nova'
export type NavLink = { href: string; label: string }
// `children` open under the item while the user is in one of its `sections` (Cadastros lists every registration).
export type NavItem = { key: NavKey; href: string; label: string; children?: NavLink[]; sections?: string[] }

const ICONS: Record<NavKey, LucideIcon> = {
  hoje: CalendarCheck,
  dashboard: LayoutDashboard,
  clientes: Users,
  vendas: Handshake,
  esteira: KanbanSquare,
  contratos: FileText,
  metas: Target,
  financeiro: WalletCards,
  repasse: HandCoins,
  comercial: FolderOpen,
  relatorios: BarChart3,
  configuracoes: Settings,
  portal: Home,
  portal_nova: FilePlus2,
}

// '/app' is the dashboard; every other item is active on its own prefix.
function isActive(pathname: string, href: string) {
  return href === '/app' ? pathname === '/app' : pathname === href || pathname.startsWith(`${href}/`)
}

export function SideNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname()
  return (
    <nav aria-label="Principal" className="flex flex-col gap-0.5">
      {items.map(({ key, href, label, children, sections }) => {
        const Icon = ICONS[key]
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
                'flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors',
                active ? 'bg-brand-soft font-semibold text-brand' : inSection ? 'font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted hover:text-ink',
              )}
            >
              <Icon size={17} aria-hidden />
              {label}
            </Link>
            {children && inSection && (
              <ul className="mb-1 ml-[21px] mt-0.5 flex flex-col gap-0.5 border-l border-line pl-2">
                {children.map(c => {
                  // Only the most specific child is marked (/app/financeiro vs /app/financeiro/empresa).
                  const on = isActive(pathname, c.href) && !children.some(o => o.href.length > c.href.length && isActive(pathname, o.href))
                  return (
                    <li key={c.href}>
                      <Link href={c.href} aria-current={on ? 'page' : undefined}
                        className={cn('block rounded-md px-2.5 py-1.5 text-[13px] transition-colors', on ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted hover:text-ink')}>
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
const PHONE_MAIN = ['hoje', 'vendas', 'clientes', 'esteira', 'portal', 'portal_nova', 'repasse']
export function BottomNav({ items, footer }: { items: NavItem[]; footer?: ReactNode }) {
  const pathname = usePathname()
  const [open, setOpen] = useState(false)
  const [at, setAt] = useState(pathname)
  // Close the menu after navigating (state reset on path change, no effect needed).
  if (at !== pathname) { setAt(pathname); setOpen(false) }
  const main = items.filter(i => PHONE_MAIN.includes(i.key)).slice(0, 4)
  const hasMore = items.some(i => !main.includes(i)) || !!footer
  const cols = main.length + (hasMore ? 1 : 0)
  return (
    <>
      {open && (
        <div role="dialog" aria-modal="true" aria-label="Menu" className="fixed inset-0 z-40 flex flex-col bg-canvas md:hidden">
          <div className="flex h-16 items-center justify-between border-b border-line px-4">
            <span className="text-base font-semibold text-ink">Menu</span>
            <button type="button" onClick={() => setOpen(false)} aria-label="Fechar menu" className="inline-flex size-10 items-center justify-center rounded-lg text-ink-soft hover:bg-surface-muted"><X size={22} aria-hidden /></button>
          </div>
          <div className="flex-1 overflow-y-auto px-3 py-3">
            <nav aria-label="Menu completo" className="flex flex-col gap-0.5">
              {items.map(({ key, href, label, children }) => {
                const Icon = ICONS[key]
                return (
                  <div key={key}>
                    <Link href={href} onClick={() => setOpen(false)} aria-current={isActive(pathname, href) ? 'page' : undefined}
                      className={cn('flex min-h-12 items-center gap-3 rounded-lg px-3 text-[15px]', isActive(pathname, href) ? 'bg-brand-soft font-semibold text-brand' : 'text-ink')}>
                      <Icon size={20} aria-hidden />{label}
                    </Link>
                    {children && (
                      <ul className="mb-1 ml-[22px] flex flex-col border-l border-line pl-3">
                        {children.map(c => (
                          <li key={c.href}><Link href={c.href} onClick={() => setOpen(false)} className="flex min-h-11 items-center text-sm text-ink-soft">{c.label}</Link></li>
                        ))}
                      </ul>
                    )}
                  </div>
                )
              })}
            </nav>
            {footer && <div className="mt-4 border-t border-line px-3 pt-4">{footer}</div>}
          </div>
        </div>
      )}
      <nav aria-label="Navegação inferior" className="fixed inset-x-0 bottom-0 z-30 grid border-t border-line bg-surface pb-[env(safe-area-inset-bottom)] md:hidden" style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}>
        {main.map(({ key, href, label }) => {
          const Icon = ICONS[key]
          const active = isActive(pathname, href)
          return (
            <Link key={key} href={href} aria-current={active ? 'page' : undefined} className={cn('flex min-h-14 flex-col items-center justify-center gap-1 text-[11px]', active ? 'font-semibold text-brand' : 'text-muted')}>
              <Icon size={21} aria-hidden />
              {label}
            </Link>
          )
        })}
        {hasMore && (
          <button type="button" onClick={() => setOpen(true)} aria-expanded={open} className="flex min-h-14 flex-col items-center justify-center gap-1 text-[11px] text-muted">
            <Menu size={21} aria-hidden />Mais
          </button>
        )}
      </nav>
    </>
  )
}
