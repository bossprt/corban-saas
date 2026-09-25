'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { BarChart3, Building2, CalendarCheck, FilePlus2, HandCoins, Home, KanbanSquare, LayoutDashboard, Settings, Target, Users, WalletCards, type LucideIcon } from 'lucide-react'
import { cn } from '@/components/ui'

export type NavKey = 'hoje' | 'dashboard' | 'clientes' | 'esteira' | 'metas' | 'financeiro' | 'repasse' | 'comercial' | 'relatorios' | 'configuracoes' | 'portal' | 'portal_nova'
export type NavItem = { key: NavKey; href: string; label: string }

const ICONS: Record<NavKey, LucideIcon> = {
  hoje: CalendarCheck,
  dashboard: LayoutDashboard,
  clientes: Users,
  esteira: KanbanSquare,
  metas: Target,
  financeiro: WalletCards,
  repasse: HandCoins,
  comercial: Building2,
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
      {items.map(({ key, href, label }) => {
        const Icon = ICONS[key]
        const active = isActive(pathname, href)
        return (
          <Link
            key={key}
            href={href}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors',
              active ? 'bg-brand-soft font-semibold text-brand' : 'text-ink-soft hover:bg-surface-muted hover:text-ink',
            )}
          >
            <Icon size={17} aria-hidden />
            {label}
          </Link>
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
