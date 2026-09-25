import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { canManageTeam } from '@/lib/rbac'
import { setupItems } from '@/lib/catalog'

// Deterministic setup status for the organization admin. Every line comes from real rows; nothing is assumed. The Auth/SMTP setup is shown
// as what it is: done outside the system, in the Supabase dashboard.
export default async function ConfigurationPage() {
  const { supabase, membership, organization } = await requireAppContext()
  if (!canManageTeam(membership.role)) return <section>
    <PageHeader title="Configuração" />
    <Card role="alert" className="p-5 text-sm text-ink-soft">A configuração da empresa é restrita aos perfis administrador e gerente.</Card>
  </section>
  const head = { count: 'exact', head: true } as const
  const [members, routes, versions, checklists, stages, banks, providers, agreements, products, modalities, orgBanks, orgAgreements, groups] = await Promise.all([
    supabase.from('organization_memberships').select('*', head).eq('status', 'active'),
    supabase.from('organization_product_routes').select('*', head).eq('status', 'active'),
    supabase.from('product_table_versions').select('*', head).eq('status', 'published'),
    supabase.from('document_checklist_templates').select('*', head).eq('status', 'published'),
    supabase.from('operational_stages').select('canonical_state').eq('is_active', true),
    supabase.from('banks').select('*', head), supabase.from('providers').select('*', head), supabase.from('agreements').select('*', head),
    supabase.from('products').select('*', head), supabase.from('modalities').select('*', head),
    supabase.from('organization_banks').select('*', head).eq('is_active', true), supabase.from('organization_agreements').select('*', head).eq('is_active', true),
    supabase.from('commission_groups').select('*', head).eq('is_active', true),
  ])
  // V3 (tenant-owned bank + agreement) OR the legacy global reference catalog
  const referenceReady = ((orgBanks.count ?? 0) > 0 && (orgAgreements.count ?? 0) > 0) || [banks, providers, agreements, products, modalities].every(r => (r.count ?? 0) > 0)
  const items = setupItems({
    activeMembers: members.count ?? 0, routes: routes.count ?? 0, publishedVersions: versions.count ?? 0, publishedChecklists: checklists.count ?? 0,
    stageStates: (stages.data ?? []).map(s => s.canonical_state), referenceReady, commissionGroups: groups.count ?? 0,
  })
  const done = items.filter(i => i.done).length
  const shortcuts: [string, string, string][] = [
    ['Equipe', '/app/equipe', 'Quem acessa a empresa, convites e papel de cada pessoa.'],
    ['Comissão', '/app/configuracao/comissao', 'Imposto, lucro da empresa, repasse e fontes isentas.'],
    ['Repasse', '/app/configuracao/repasse', 'Fechamento ou conta interna, frequência e limite de desconto do saldo negativo.'],
    ['Etapas da esteira', '/app/configuracao/etapas', 'Nome, ordem e prazo de cada etapa.'],
    ['API', '/app/configuracao/api', 'Chaves para outros sistemas (ex.: DeskcommCRM) enviarem leads.'],
    ['Papéis e permissões', '/app/configuracao/papeis', 'O que cada papel pode fazer em cada módulo e quais dados enxerga.'],
  ]
  return <section>
    <PageHeader title="Configuração" description={`${organization.name}: o que já está configurado e o que falta antes de o operador trabalhar.`} />
    <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {shortcuts.map(([label, href, hint]) => (
        <Link key={href} href={href} className="group flex items-start justify-between gap-3 rounded-[14px] border border-line bg-surface p-4 hover:border-line-strong hover:bg-surface-muted">
          <span><span className="block text-sm font-semibold text-ink">{label}</span><span className="mt-1 block text-[13px] text-ink-soft">{hint}</span></span>
          <ChevronRight size={16} aria-hidden className="mt-0.5 shrink-0 text-muted group-hover:text-ink" />
        </Link>
      ))}
    </div>

    <Card className="mt-4">
      <CardHeader title="O que falta configurar" action={<span className="num text-sm text-muted"><strong className="text-ink">{done}</strong> de {items.length} prontos</span>} />
      <ul className="mt-3">
        {items.map(i => (
          <li key={i.key}>
            <Link href={i.href} className="flex items-start justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
              <span><span className="block text-sm font-medium text-ink">{i.label}</span><span className="block text-[13px] text-ink-soft">{i.hint}</span></span>
              <Badge tone={i.done ? 'received' : 'diverged'} className="shrink-0">{i.done ? 'Pronto' : 'Pendente'}</Badge>
            </Link>
          </li>
        ))}
      </ul>
    </Card>

    <Card className="mt-4">
      <CardHeader title="Bom saber" />
      <ul className="grid gap-2 px-5 pb-5 pt-3 text-sm text-ink-soft">
        <li>Login, convites e e-mails (Site URL, SMTP): configurados no painel do Supabase pelo dono; o sistema não consegue verificar isso daqui.</li>
        <li>Comissão: o vendedor vê só a parte dele, e só nas propostas dele. O que a empresa recebe do banco, o imposto e o lucro ficam com quem tem acesso ao financeiro; as taxas das tabelas, com supervisor, gerente e administrador.</li>
      </ul>
    </Card>
  </section>
}
