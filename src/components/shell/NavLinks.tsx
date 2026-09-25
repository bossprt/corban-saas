'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { BarChart3, CalendarCheck, FilePlus2, FolderOpen, HandCoins, Home, KanbanSquare, LayoutDashboard, Settings, Target, Users, WalletCards, type LucideIcon } from 'lucide-react'
import { cn } from '@/components/ui'

export type NavKey = 'hoje' | 'dashboard' | 'clientes' | 'esteira' | 'metas' | 'financeiro' | 'repasse' | 'comercial' | 'relatorios' | 'configuracoes' | 'portal' | 'portal_nova'
export type NavLink = { href: string; label: string }
// `children` open under the item while the user is in one of its `sections` (Cadastros lists every registration).
export type NavItem = { key: NavKey; href: string; label: string; children?: NavLink[]; sections?: string[] }

const ICONS: Record<NavKey, LucideIcon> = {
  hoje: CalendarCheck,
  dashboard: LayoutDashboard,
  clientes: Users,
  esteira: KanbanSquare,
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
                  const on = isActive(pathname, c.href)
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

// Phone navigation: the four most used destinations plus the rest behind the side menu.
export function BottomNav({ items }: { items: NavItem[] }) {
  const pathname = usePathname()
  const main = items.filter(i => ['hoje', 'clientes', 'esteira', 'financeiro', 'dashboard', 'portal', 'portal_nova', 'repasse'].includes(i.key)).slice(0, 4)
  return (
    <nav aria-label="Navegação inferior" className="fixed inset-x-0 bottom-0 z-30 grid border-t border-line bg-surface pb-[env(safe-area-inset-bottom)] md:hidden" style={{ gridTemplateColumns: `repeat(${main.length}, minmax(0, 1fr))` }}>
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
    </nav>
  )
}
