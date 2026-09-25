import Link from 'next/link'
import { ChevronRight, Plus } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { BASIS_SHORT, pctText, type HierarchyBasis } from '@/lib/commission/groupRule'
import { setActive } from '../actions'

// Seller groups (Corretor, Parceiro, Balcão...): each one is the payout rule of the sellers in it, one to one.
export default async function SellerGroupsPage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Grupos de vendedores" /><Card className="p-5 text-sm text-ink-soft">Seu papel não vê as regras de repasse.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const [{ data: groups }, { data: rules }, { data: sellers }] = await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('group_id,version,own_production,supervisor_basis,supervisor_pct,manager_basis,manager_pct').order('version', { ascending: false }),
    supabase.from('commercial_sellers').select('commission_group_id').eq('is_active', true),
  ])
  const current = new Map<string, NonNullable<typeof rules>[number]>()
  for (const r of rules ?? []) if (!current.has(r.group_id)) current.set(r.group_id, r)
  const sellerCount = new Map<string, number>()
  for (const s of sellers ?? []) sellerCount.set(s.commission_group_id, (sellerCount.get(s.commission_group_id) ?? 0) + 1)
  const pending = (groups ?? []).filter(g => g.is_active && !current.has(g.id)).length

  return (
    <section>
      <PageHeader
        title="Grupos de vendedores"
        description="Cada grupo é a regra de repasse de quem está nele: o vendedor cadastrado como Corretor segue a regra do grupo Corretor. Cadastre os grupos antes de importar as tabelas."
        actions={canEdit ? <ButtonLink href="/app/comercial/grupos/novo"><Plus size={16} aria-hidden />Novo grupo</ButtonLink> : undefined}
      />
      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Grupos <Badge tone="neutral">{groups?.length ?? 0}</Badge>{pending > 0 && <Badge tone="pending">{pending} com regra pendente</Badge>}</span>} />
        <ul className="mt-3">
          {(groups ?? []).map(g => {
            const r = current.get(g.id)
            return (
              <li key={g.id} className="flex flex-wrap items-center gap-3 border-t border-line px-5 py-3">
                <Link href={`/app/comercial/grupos/${g.id}`} className="group flex min-w-0 flex-1 items-center justify-between gap-3">
                  <span className="min-w-0">
                    <span className="flex flex-wrap items-center gap-2 text-sm font-semibold text-ink">
                      {g.name}
                      {!r ? <Badge tone="pending">Regra pendente</Badge> : r.own_production ? <Badge tone="brand">Produção própria</Badge> : <Badge tone="received">Regra configurada</Badge>}
                      {!g.is_active && <Badge tone="neutral">Inativo</Badge>}
                    </span>
                    <span className="block text-[13px] text-ink-soft">
                      {sellerCount.get(g.id) ?? 0} vendedor(es)
                      {r && ` · supervisor ${pctText(r.supervisor_pct)}% sobre ${BASIS_SHORT[r.supervisor_basis as HierarchyBasis]} · gerente ${pctText(r.manager_pct)}% sobre ${BASIS_SHORT[r.manager_basis as HierarchyBasis]}`}
                    </span>
                  </span>
                  <ChevronRight size={16} aria-hidden className="shrink-0 text-muted group-hover:text-ink" />
                </Link>
                {canEdit && (
                  <form action={setActive}>
                    <input type="hidden" name="return_to" value="/app/comercial/grupos" />
                    <input type="hidden" name="kind" value="group" />
                    <input type="hidden" name="id" value={g.id} />
                    <input type="hidden" name="active" value={g.is_active ? 'false' : 'true'} />
                    <SubmitButton className="text-xs text-muted underline hover:text-ink" pendingText="...">{g.is_active ? 'Desativar' : 'Reativar'}</SubmitButton>
                  </form>
                )}
              </li>
            )
          })}
          {!groups?.length && <li className="border-t border-line px-5 py-4 text-sm text-muted">Nenhum grupo cadastrado.</li>}
        </ul>
      </Card>
    </section>
  )
}
