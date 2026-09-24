import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { canManageTeam } from '@/lib/rbac'
import { setupItems } from '@/lib/catalog'

// Deterministic setup status for the organization admin. Every line comes from real rows; nothing is assumed. Integrations, the worker and the
// Auth/SMTP setup are shown as what they are: optional for the first internal pilot (integrations, worker) or outside the system (Auth/SMTP).
export default async function ConfigurationPage() {
  const { supabase, membership, organization } = await requireAppContext()
  if (!canManageTeam(membership.role)) return <section>
    <h1 className="text-3xl font-semibold">Configuração</h1>
    <p role="alert" className="mt-3 rounded-xl border border-slate-800 p-5 text-sm text-slate-300">A configuração da organização é restrita aos perfis administrador e gerente.</p>
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
  return <section>
    <h1 className="text-3xl font-semibold">Configuração do piloto</h1>
    <p className="mt-2 text-sm text-slate-400">{organization.name}: o que já está configurado e o que falta antes de o operador trabalhar. Conta apenas dados reais desta organização.</p>
    <div className="mt-4 grid gap-3 sm:grid-cols-2">
      <Link href="/app/equipe" className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600"><strong>Equipe</strong><span className="mt-1 block text-xs text-slate-400">Quem acessa a empresa, convites e papel de cada pessoa.</span></Link>
      <Link href="/app/configuracao/comissao" className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600"><strong>Comissão</strong><span className="mt-1 block text-xs text-slate-400">Imposto, lucro da empresa, repasse e fontes isentas.</span></Link>
      <Link href="/app/configuracao/etapas" className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600"><strong>Etapas da esteira</strong><span className="mt-1 block text-xs text-slate-400">Nome, ordem e prazo de cada etapa.</span></Link>
      <Link href="/app/configuracao/api" className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600"><strong>API</strong><span className="mt-1 block text-xs text-slate-400">Chaves para outros sistemas (ex.: DeskcommCRM) enviarem leads.</span></Link>
      <Link href="/app/configuracao/papeis" className="rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600"><strong>Papéis e permissões</strong><span className="mt-1 block text-xs text-slate-400">O que cada papel pode fazer em cada módulo e quais dados enxerga.</span></Link>
    </div>
    <p className="mt-4 text-sm"><strong>{done}</strong> de {items.length} itens prontos.</p>
    <ul className="mt-3 space-y-2">{items.map(i => <li key={i.key}><Link href={i.href} className="flex items-start justify-between gap-3 rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm hover:border-slate-600">
      <span><span className="font-medium">{i.label}</span><span className="block text-xs text-slate-400">{i.hint}</span></span>
      <span className={i.done ? 'text-emerald-400' : 'text-amber-300'}>{i.done ? 'Pronto' : 'Pendente'}</span></Link></li>)}</ul>
    <h2 className="mt-8 text-lg font-semibold">Fora do sistema ou opcional</h2>
    <ul className="mt-2 space-y-1 text-sm text-slate-400">
      <li>Integrações e processamento automático: <strong className="text-slate-300">opcional para o piloto inicial</strong> (nenhum banco real está ligado). Veja a prontidão em Integrações.</li>
      <li>Login, convites e e-mails (Site URL, SMTP): configurados no painel do Supabase pelo dono; o sistema não consegue verificar isso daqui.</li>
      <li>Comissão: a decisão sobre quem vê comissão esperada é do dono; hoje somente supervisor, gerente e administrador veem.</li>
    </ul>
  </section>
}
