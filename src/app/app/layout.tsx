import Link from 'next/link'
import { LayoutDashboard, Users, FileText, Workflow, Landmark } from 'lucide-react'
import { requireAppContext } from '@/lib/appContext'

const nav = [
  { href: '/app', label: 'Visão geral', icon: LayoutDashboard },
  { href: '/app/clientes', label: 'Clientes', icon: Users },
  { href: '/app/propostas', label: 'Propostas', icon: FileText },
  { href: '/app/operacao', label: 'Operação', icon: Workflow },
]

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { organization, membership } = await requireAppContext()
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 md:flex">
      <aside className="border-b border-slate-800 bg-slate-900/70 p-5 md:min-h-screen md:w-64 md:border-b-0 md:border-r">
        <div className="mb-8 flex items-center gap-3">
          <div className="rounded-xl bg-emerald-500/15 p-2 text-emerald-400"><Landmark size={22}/></div>
          <div><div className="font-semibold">Corban OS</div><div className="text-xs text-slate-400">{organization?.name ?? 'Organização'}</div></div>
        </div>
        <nav className="grid grid-cols-2 gap-2 md:grid-cols-1">
          {nav.map(({href,label,icon:Icon}) => <Link key={href} href={href} className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm text-slate-300 hover:bg-slate-800 hover:text-white"><Icon size={17}/>{label}</Link>)}
        </nav>
        <div className="mt-8 border-t border-slate-800 pt-4 text-xs text-slate-500">Perfil: {membership.role}</div>
      </aside>
      <main className="flex-1 p-5 md:p-8">{children}</main>
    </div>
  )
}
