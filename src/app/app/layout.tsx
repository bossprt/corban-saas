import Link from 'next/link'
import { LayoutDashboard, Users, UserPlus, FileText, Workflow, Landmark, Library, LogOut, Calculator, FolderLock, Network, Plug, Upload, WalletCards, Settings, ShieldCheck } from 'lucide-react'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam, canViewCommission } from '@/lib/rbac'
import { ROLE_LABEL } from '@/lib/team'
import { Suspense } from 'react'
import { FlashBanner } from '@/components/FlashBanner'
import { signOut } from './actions'

// `show` only decides what is offered in the menu; every page, action and RPC enforces the role again (a hidden link is not authorization).
const nav: { href: string; label: string; icon: typeof Users; show?: (role: string) => boolean }[] = [
  { href: '/app', label: 'Visão geral', icon: LayoutDashboard },
  { href: '/app/leads', label: 'Leads', icon: UserPlus },
  { href: '/app/clientes', label: 'Clientes', icon: Users },
  { href: '/app/comercial', label: 'Modelo comercial', icon: Library, show: r => atLeast(r, 'supervisor') },
  { href: '/app/catalogo', label: 'Catálogo (anterior)', icon: Library, show: r => atLeast(r, 'supervisor') },
  { href: '/app/atencao', label: 'Central de atenção', icon: ShieldCheck, show: r => atLeast(r, 'supervisor') },
  { href: '/app/simulacoes', label: 'Simulações', icon: Calculator },
  { href: '/app/propostas', label: 'Propostas', icon: FileText },
  { href: '/app/documentos', label: 'Documentos', icon: FolderLock },
  { href: '/app/operacao', label: 'Operação', icon: Workflow },
  { href: '/app/rede', label: 'Rede comercial', icon: Network, show: canManageTeam },
  { href: '/app/importacoes', label: 'Importações', icon: Upload, show: r => atLeast(r, 'supervisor') },
  { href: '/app/integracoes', label: 'Integrações', icon: Plug, show: r => atLeast(r, 'supervisor') },
  { href: '/app/financeiro', label: 'Financeiro e conciliação', icon: WalletCards, show: canViewCommission },
  { href: '/app/equipe', label: 'Equipe', icon: ShieldCheck, show: canManageTeam },
  { href: '/app/configuracao', label: 'Configuração', icon: Settings, show: canManageTeam },
]

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { organization, membership, membershipCount } = await requireAppContext()

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 md:flex">
      <aside className="border-b border-slate-800 bg-slate-900/70 p-5 md:min-h-screen md:w-64 md:border-b-0 md:border-r">
        <div className="mb-8 flex items-center gap-3">
          <div className="rounded-xl bg-emerald-500/15 p-2 text-emerald-400"><Landmark size={22}/></div>
          <div><div className="font-semibold">Corban OS</div><div className="text-xs text-slate-400">{organization.name}</div></div>
        </div>
        <nav className="grid grid-cols-2 gap-2 md:grid-cols-1">
          {nav.filter(n => !n.show || n.show(membership.role)).map(({ href, label, icon: Icon }) => (
            <Link key={href} href={href} className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm text-slate-300 hover:bg-slate-800 hover:text-white">
              <Icon size={17}/>{label}
            </Link>
          ))}
        </nav>
        <div className="mt-8 border-t border-slate-800 pt-4 text-xs text-slate-500">Perfil: {ROLE_LABEL[membership.role] ?? membership.role}{membershipCount > 1 && <> · <Link href="/organizacao" className="underline">trocar organização</Link></>}</div>
        <form action={signOut} className="mt-3">
          <button type="submit" className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-slate-400 hover:bg-slate-800 hover:text-white">
            <LogOut size={16}/>Sair
          </button>
        </form>
      </aside>
      <main className="min-w-0 flex-1 p-4 md:p-8"><Suspense fallback={null}><FlashBanner /></Suspense>{children}</main>
    </div>
  )
}
