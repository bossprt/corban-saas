import Link from 'next/link'
import { LogOut } from 'lucide-react'
import { Suspense } from 'react'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam } from '@/lib/rbac'
import { can, type Permission } from '@/lib/access'
import { ROLE_LABEL } from '@/lib/team'
import { FlashBanner } from '@/components/FlashBanner'
import { ImprovementLink } from '@/components/shell/ImprovementLink'
import { BottomNav, SideNav, type NavItem } from '@/components/shell/NavLinks'
import { CommandPalette } from '@/components/shell/CommandPalette'
import { isPortalUser } from '@/lib/portal'
import { REGISTRATIONS, REGISTRATION_SECTIONS } from '@/lib/registrations'
import { signOut } from './actions'
import { BillingNotice } from '@/components/shell/BillingNotice'
import { isPlatformAdmin } from '@/lib/platform.server'
import { brandCss, logoUrl } from '@/lib/branding'
import { publicSupabaseEnv } from '@/lib/env'

// `show` only decides what the menu offers; every page, action and RPC enforces the role again (a hidden link is not authorization).
// `module`: the item appears only while that module is on for the company (plan).
const NAV: (NavItem & { show?: (role: string) => boolean; module?: string; perm?: Permission })[] = [
  { key: 'hoje', href: '/app/hoje', label: 'Hoje', sections: ['/app/atencao', '/app/operacao'] },
  { key: 'dashboard', href: '/app', label: 'Visão geral' },
  { key: 'clientes', href: '/app/clientes', label: 'Clientes', module: 'clientes' },
  // Sales CRM (V2): campaigns, queue and the team's board.
  { key: 'vendas', href: '/app/crm', label: 'Vendas', module: 'leads', perm: 'leads.view' },
  { key: 'esteira', href: '/app/propostas', label: 'Esteira', module: 'esteira' },
  // Contract search with the commission of each one (part C1).
  { key: 'contratos', href: '/app/contratos', label: 'Contratos', module: 'esteira' },
  { key: 'financeiro', href: '/app/financeiro', label: 'Financeiro', module: 'financeiro', perm: 'financeiro.view' },
  // Everyone may have a payout account (their own statement); finance sees all accounts on the same screen.
  { key: 'repasse', href: '/app/repasse', label: 'Repasse', module: 'repasse' },
  // Order follows the money (owner, 06/11/2026): sale → pipeline → contract → commission received → payout, then goals.
  { key: 'metas', href: '/app/metas', label: 'Metas' },
  // Everything the company registers (banks, tables, seller groups, sellers, team...) under one item; clients stay separate.
  { key: 'comercial', href: '/app/cadastros', label: 'Cadastros', show: r => atLeast(r, 'supervisor'), module: 'comercial', sections: REGISTRATION_SECTIONS },
  { key: 'relatorios', href: '/app/relatorios', label: 'Relatórios', module: 'relatorios' },
  { key: 'configuracoes', href: '/app/configuracao', label: 'Configurações', show: canManageTeam },
]

// Finance: the commission received from the banks and the company finance (F6.5).
// Vendas: the board and the simulator (owner, 08/10/2026: the simulator was hard to find under Esteira).
const SALES_PAGES = [
  { href: '/app/crm', label: 'Quadro de vendas' },
  { href: '/app/simulacoes', label: 'Simulador' },
  { href: '/app/ranking', label: 'Ranking' },
]

const FINANCE_PAGES = [
  { href: '/app/financeiro', label: 'Comissão recebida' },
  { href: '/app/financeiro/empresa', label: 'Contas a pagar e receber' },
  { href: '/app/financeiro/empresa/extrato', label: 'Extrato bancário' },
  { href: '/app/financeiro/empresa/relatorios', label: 'Fluxo de caixa e DRE' },
]

// Broker portal (F7): a member with the 'corretor' role gets only their own pages, mobile-first.
const PORTAL_NAV: NavItem[] = [
  { key: 'portal', href: '/app/portal', label: 'Início' },
  { key: 'portal_nova', href: '/app/portal/nova', label: 'Nova proposta' },
  { key: 'repasse', href: '/app/repasse', label: 'Extrato' },
]

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { organization, membership, membershipCount, modules, access, billing, user } = await requireAppContext()
  const portal = isPortalUser(access?.roleKey, modules)
  // Under Hoje: the alert center (supervisor and above, as the page itself requires) and the digitization queue.
  const todayPages = [
    ...(atLeast(membership.role, 'supervisor') ? [{ href: '/app/atencao', label: 'Central de atenção' }] : []),
    ...(modules.has('esteira') ? [{ href: '/app/operacao', label: 'Operação' }] : []),
  ]
  const hoje = todayPages.length ? [{ href: '/app/hoje', label: 'Hoje' }, ...todayPages] : []
  // Platform link only for an active platform administrator (a failure hides the link).
  const platformAdmin = !portal && await isPlatformAdmin(user.id)
  const isAdmin = membership.role === 'admin'
  const items: NavItem[] = portal ? PORTAL_NAV : NAV.filter(n => (!n.show || n.show(membership.role)) && (!n.module || modules.has(n.module)) && (!n.perm || can(access, n.perm))).map(({ key, href, label, sections }) => ({
    key, href, label, sections,
    ...(key === 'comercial' ? { children: REGISTRATIONS.filter(r => !r.teamOnly || canManageTeam(membership.role)).map(r => ({ href: r.href, label: r.label })) } : {}),
    ...(key === 'financeiro' ? { children: FINANCE_PAGES } : {}),
    ...(key === 'vendas' ? { children: SALES_PAGES } : {}),
    ...(key === 'hoje' ? { children: hoje.length ? hoje : undefined } : {}),
  }))
  const initial = (organization.name ?? 'C').trim().charAt(0).toUpperCase()
  // The company's own colors and logo (Configurações > Aparência); only validated #rrggbb colors reach the CSS.
  const look = organization as typeof organization & { brand_color?: string | null; accent_color?: string | null; logo_path?: string | null }
  const css = brandCss(look.brand_color, look.accent_color)
  const logo = logoUrl(publicSupabaseEnv().url, organization.id, look.logo_path)

  return (
    <div className="min-h-screen bg-canvas text-ink md:flex">
      {css ? <style>{css}</style> : null}
      <aside className="hidden w-[232px] shrink-0 flex-col gap-1 border-r border-line bg-surface px-3.5 py-5 md:sticky md:top-0 md:flex md:h-screen">
        {logo ? (
          <div className="mb-4 px-2">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={logo} alt={organization.name} className="h-12 w-auto max-w-[190px] object-contain object-left" />
          </div>
        ) : (
          <div className="mb-4 flex items-center gap-2.5 px-2">
            <div className="flex size-8 items-center justify-center rounded-lg bg-brand text-[15px] font-bold text-white" aria-hidden>{initial}</div>
            <div className="min-w-0">
              <div className="truncate text-[15px] font-bold tracking-tight" title={organization.name}>{organization.name}</div>
              <div className="text-[11px] text-muted">Corban</div>
            </div>
          </div>
        )}
        <SideNav items={items} />
        <div className="mt-auto border-t border-line px-2 pt-3 text-xs text-muted">
          <div>{access?.roleName ?? ROLE_LABEL[membership.role] ?? membership.role}</div>
          {membershipCount > 1 && <Link href="/organizacao" className="underline hover:text-ink">Trocar empresa</Link>}
          {isAdmin && <div><Link href="/mensalidade" className="underline hover:text-ink">Mensalidade</Link></div>}
          {platformAdmin && <div><Link href="/platform" className="underline hover:text-ink">Plataforma</Link></div>}
          {!portal && <div className="mt-2"><ImprovementLink /></div>}
          <form action={signOut}>
            <button type="submit" className="flex items-center gap-2 rounded-lg py-1.5 text-sm text-ink-soft hover:text-ink">
              <LogOut size={15} aria-hidden />Sair
            </button>
          </form>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-20 flex h-14 items-center gap-3 border-b border-line bg-surface px-4 md:h-[58px] md:px-8">
          <div className="flex size-8 items-center justify-center rounded-lg bg-brand text-sm font-bold text-white md:hidden" aria-hidden>{initial}</div>
          <CommandPalette nav={items} />
        </header>
        <main className="min-w-0 flex-1 px-4 pb-24 pt-6 md:px-8 md:pb-10">
          <Suspense fallback={null}><FlashBanner /></Suspense>
          {membership.role === 'admin' && billing?.period && <BillingNotice billing={billing} />}
          {children}
        </main>
      </div>

      <BottomNav items={items} footer={
        <div className="text-sm text-muted">
          <div>{access?.roleName ?? ROLE_LABEL[membership.role] ?? membership.role} · {organization.name}</div>
          {membershipCount > 1 && <Link href="/organizacao" className="mt-2 inline-block underline">Trocar empresa</Link>}
          {isAdmin && <div><Link href="/mensalidade" className="flex min-h-11 items-center text-[15px] text-ink">Mensalidade</Link></div>}
          {platformAdmin && <div><Link href="/platform" className="flex min-h-11 items-center text-[15px] text-ink">Plataforma</Link></div>}
          {!portal && <div className="mt-3"><ImprovementLink className="flex min-h-11 items-center gap-2 text-[15px] text-ink" /></div>}
          <form action={signOut}>
            <button type="submit" className="flex min-h-11 items-center gap-2 text-[15px] text-ink"><LogOut size={18} aria-hidden />Sair</button>
          </form>
        </div>
      } />
    </div>
  )
}
