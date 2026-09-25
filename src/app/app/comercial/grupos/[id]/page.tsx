import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import type { HierarchyBasis, ReferenceKind } from '@/lib/commission/groupRule'
import { saveSellerGroup } from '../actions'
import { GroupForm, type GroupRuleValues } from '../GroupForm'

// One seller group: its payout rule in the same form used to create it ("novo" creates a new group).
export default async function SellerGroupPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const isNew = id === 'novo'
  if (!isNew && !isUuid(id)) notFound()
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Grupo de vendedores" /><Card className="p-5 text-sm text-ink-soft">Seu papel não vê as regras de repasse.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  if (isNew && !canEdit) return <section><PageHeader title="Novo grupo" /><Card className="p-5 text-sm text-ink-soft">Seu papel não cadastra grupos.</Card></section>

  const [{ data: group }, { data: components }, { data: groups }, { data: rules }] = await Promise.all([
    isNew ? Promise.resolve({ data: null }) : supabase.from('commission_groups').select('id,name,is_active').eq('id', id).maybeSingle(),
    supabase.from('commission_component_types').select('tech_key,name,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active', true).order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('id,group_id,version,own_production,supervisor_basis,supervisor_pct,manager_basis,manager_pct,created_at').order('version', { ascending: false }),
  ])
  if (!isNew && !group) notFound()

  // Current rule of each group = its highest version.
  const current = new Map<string, NonNullable<typeof rules>[number]>()
  for (const r of rules ?? []) if (!current.has(r.group_id)) current.set(r.group_id, r)
  const mine = group ? current.get(group.id) : undefined
  const { data: items } = mine
    ? await supabase.from('commission_group_rule_items').select('reference_kind,reference_group_id,distributed_pct,commission_component_types(tech_key)').eq('rule_id', mine.id)
    : { data: [] }
  const rule: GroupRuleValues | undefined = mine && {
    own_production: mine.own_production,
    supervisor_basis: mine.supervisor_basis as HierarchyBasis, supervisor_pct: String(mine.supervisor_pct),
    manager_basis: mine.manager_basis as HierarchyBasis, manager_pct: String(mine.manager_pct),
    items: Object.fromEntries((items ?? []).map(i => {
      const t = i.commission_component_types as unknown as { tech_key: string } | null
      return [t?.tech_key ?? '', { reference_kind: i.reference_kind as ReferenceKind, reference_group_id: i.reference_group_id, distributed_pct: String(i.distributed_pct) }]
    })),
  }
  // Columns another group can read: active groups other than this one that are not own production.
  const otherGroups = (groups ?? []).filter(g => g.id !== group?.id && !current.get(g.id)?.own_production)
  const versions = group ? (rules ?? []).filter(r => r.group_id === group.id).length : 0

  return (
    <section>
      <Link href="/app/comercial/grupos" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Grupos de vendedores</Link>
      <PageHeader
        title={isNew ? 'Novo grupo de vendedores' : group!.name}
        description={isNew ? 'Cadastre o grupo antes de importar as tabelas: cada grupo ganha sua coluna de repasse.' : (
          <span className="flex flex-wrap items-center gap-2">
            {!mine ? <Badge tone="pending">Regra pendente</Badge> : mine.own_production ? <Badge tone="brand">Produção própria</Badge> : <Badge tone="received">Regra configurada</Badge>}
            {!group!.is_active && <Badge tone="neutral">Inativo</Badge>}
            {mine && <span>Versão {mine.version} de {versions} · desde {new Date(mine.created_at).toLocaleDateString('pt-BR')}</span>}
          </span>
        )}
      />
      <Card className="p-5">
        <GroupForm key={mine?.id ?? 'novo'} action={saveSellerGroup} group={group ? { id: group.id, name: group.name } : undefined} rule={rule}
          components={(components ?? []).map(c => ({ tech_key: c.tech_key, name: c.name }))} otherGroups={otherGroups.map(g => ({ id: g.id, name: g.name }))} canEdit={canEdit} />
      </Card>
    </section>
  )
}
