import Link from 'next/link'
import { LogOut } from 'lucide-react'
import { Suspense } from 'react'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam } from '@/lib/rbac'
import { can, type Permission } from '@/lib/access'
import { ROLE_LABEL } from '@/lib/team'
import { FlashBanner } from '@/components/FlashBanner'
import { BottomNav, SideNav, type NavItem } from '@/components/shell/NavLinks'
import { CommandPalette } from '@/components/shell/CommandPalette'
import { isPortalUser } from '@/lib/portal'
import { signOut } from './actions'

// `show` only decides what the menu offers; every page, action and RPC enforces the role again (a hidden link is not authorization).
// `module`: the item appears only while that module is on for the company (plan).
const NAV: (NavItem & { show?: (role: string) => boolean; module?: string; perm?: Permission })[] = [
  { key: 'hoje', href: '/app/hoje', label: 'Hoje' },
  { key: 'dashboard', href: '/app', label: 'Dashboard' },
  { key: 'clientes', href: '/app/clientes', label: 'Clientes', module: 'clientes' },
  { key: 'esteira', href: '/app/propostas', label: 'Esteira', module: 'esteira' },
  { key: 'metas', href: '/app/metas', label: 'Metas' },
  { key: 'financeiro', href: '/app/financeiro', label: 'Financeiro', module: 'financeiro', perm: 'financeiro.view' },
  // Everyone may have a payout account (their own statement); finance sees all accounts on the same screen.
  { key: 'repasse', href: '/app/repasse', label: 'Repasse', module: 'repasse' },
  { key: 'comercial', href: '/app/comercial', label: 'Comercial', show: r => atLeast(r, 'supervisor'), module: 'comercial' },
  { key: 'relatorios', href: '/app/relatorios', label: 'Relatórios', module: 'relatorios' },
  { key: 'configuracoes', href: '/app/configuracao', label: 'Configurações', show: canManageTeam },
]

// Broker portal (F7): a member with the 'corretor' role gets only their own pages, mobile-first.
const PORTAL_NAV: NavItem[] = [
  { key: 'portal', href: '/app/portal', label: 'Início' },
  { key: 'portal_nova', href: '/app/portal/nova', label: 'Nova proposta' },
  { key: 'repasse', href: '/app/repasse', label: 'Extrato' },
]

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { organization, membership, membershipCount, modules, access } = await requireAppContext()
  const items: NavItem[] = isPortalUser(access?.roleKey, modules) ? PORTAL_NAV : NAV.filter(n => (!n.show || n.show(membership.role)) && (!n.module || modules.has(n.module)) && (!n.perm || can(access, n.perm))).map(({ key, href, label }) => ({ key, href, label }))
  const initial = (organization.name ?? 'C').trim().charAt(0).toUpperCase()

  return (
    <div className="min-h-screen bg-canvas text-ink md:flex">
      <aside className="hidden w-[232px] shrink-0 flex-col gap-1 border-r border-line bg-surface px-3.5 py-5 md:sticky md:top-0 md:flex md:h-screen">
        <div className="mb-4 flex items-center gap-2.5 px-2">
          <div className="flex size-8 items-center justify-center rounded-lg bg-brand text-[15px] font-bold text-white" aria-hidden>C</div>
          <div className="min-w-0">
            <div className="text-[15px] font-bold tracking-tight">Corban</div>
            <div className="truncate text-[11px] text-muted" title={organization.name}>{organization.name}</div>
          </div>
        </div>
        <SideNav items={items} />
        <div className="mt-auto border-t border-line px-2 pt-3 text-xs text-muted">
          <div>{access?.roleName ?? ROLE_LABEL[membership.role] ?? membership.role}</div>
          {membershipCount > 1 && <Link href="/organizacao" className="underline hover:text-ink">Trocar empresa</Link>}
          <form action={signOut} className="mt-2">
            <button type="submit" className="flex items-center gap-2 rounded-lg py-1.5 text-sm text-ink-soft hover:text-ink">
              <LogOut size={15} aria-hidden />Sair
            </button>
          </form>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-20 flex h-16 items-center gap-3 border-b border-line bg-canvas/90 px-4 backdrop-blur md:px-8">
          <div className="flex size-8 items-center justify-center rounded-lg bg-brand text-sm font-bold text-white md:hidden" aria-hidden>{initial}</div>
          <CommandPalette nav={items} />
        </header>
        <main className="min-w-0 flex-1 px-4 pb-24 pt-6 md:px-8 md:pb-10">
          <Suspense fallback={null}><FlashBanner /></Suspense>
          {children}
        </main>
      </div>

      <BottomNav items={items} />
    </div>
  )
}
