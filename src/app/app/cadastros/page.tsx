import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canManageTeam } from '@/lib/rbac'
import { REGISTRATIONS } from '@/lib/registrations'

// Central de cadastros: every registration of the company in one place (the same entries the side menu lists under "Cadastros").
export default async function RegistrationsHubPage() {
  const { membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) {
    return <section><PageHeader title="Cadastros" /><Card className="p-5 text-sm text-ink-soft">Área restrita a supervisão, gerência e administração.</Card></section>
  }
  const items = REGISTRATIONS.filter(r => !r.teamOnly || canManageTeam(membership.role))
  return (
    <section>
      <PageHeader title="Cadastros" description="Tudo o que a empresa cadastra: bancos, convênios, tabelas, grupos de vendedores, vendedores e equipe." />
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {items.map(r => (
          <Link key={r.href} href={r.href} className="group flex items-start justify-between gap-3 rounded-[14px] border border-line bg-surface p-4 hover:border-line-strong hover:bg-surface-muted">
            <span><span className="block text-sm font-semibold text-ink">{r.label}</span><span className="mt-1 block text-[13px] text-ink-soft">{r.hint}</span></span>
            <ChevronRight size={16} aria-hidden className="mt-0.5 shrink-0 text-muted group-hover:text-ink" />
          </Link>
        ))}
      </div>
    </section>
  )
}
