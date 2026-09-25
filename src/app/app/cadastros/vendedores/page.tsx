import Link from 'next/link'
import { ChevronRight, Plus } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { formatPhone } from '@/lib/cpf'
import { atLeast } from '@/lib/rbac'
import { CATEGORY_LABEL, sellerCode } from '@/lib/sellers'

// Sellers: each one belongs to one seller group and is paid by that group's rule. The row opens the seller file.
export default async function SellersPage() {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Vendedores" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const [groups, sellers, profiles] = await Promise.all([
    supabase.from('commission_groups').select('id,name'),
    supabase.from('commercial_sellers').select('id,code,name,seller_category,commission_group_id,is_active,user_id').order('code'),
    supabase.from('seller_profiles').select('seller_id,phone,email'),
  ])
  const groupName = new Map((groups.data ?? []).map(x => [x.id, x.name]))
  const profile = new Map((profiles.data ?? []).map(p => [p.seller_id, p]))

  return (
    <section>
      <PageHeader
        title="Vendedores"
        description={<>Cada vendedor pertence a um <Link href="/app/comercial/grupos" className="text-brand hover:text-brand-strong">grupo de vendedores</Link> e recebe pela regra desse grupo.</>}
        actions={canEdit ? <ButtonLink href="/app/cadastros/vendedores/novo"><Plus size={16} aria-hidden />Novo vendedor</ButtonLink> : undefined}
      />
      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Vendedores <Badge tone="neutral">{sellers.data?.length ?? 0}</Badge></span>} />
        <ul className="mt-3">
          {!(sellers.data ?? []).length && <li className="border-t border-line px-5 py-4 text-sm text-muted">Nenhum vendedor cadastrado.</li>}
          {(sellers.data ?? []).map(s => {
            const p = profile.get(s.id)
            const incomplete = !p?.phone || !p?.email
            return (
              <li key={s.id}>
                <Link href={`/app/cadastros/vendedores/${s.id}`} className="group flex flex-wrap items-center gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
                  <span className="num w-12 shrink-0 font-mono text-sm text-muted">{sellerCode(s.code)}</span>
                  <span className="min-w-0 flex-1">
                    <span className="block text-sm font-semibold text-ink">{s.name}</span>
                    <span className="block text-[13px] text-ink-soft">{CATEGORY_LABEL[s.seller_category] ?? s.seller_category} · Grupo: {groupName.get(s.commission_group_id) ?? '—'}{p?.phone ? ` · ${formatPhone(p.phone)}` : ''}</span>
                  </span>
                  <span className="flex items-center gap-2">
                    {incomplete && <Badge tone="pending">Cadastro incompleto</Badge>}
                    {s.user_id && <Badge tone="brand">Com acesso</Badge>}
                    <Badge tone={s.is_active ? 'received' : 'neutral'}>{s.is_active ? 'Ativo' : 'Inativo'}</Badge>
                    <ChevronRight size={16} aria-hidden className="text-muted group-hover:text-ink" />
                  </span>
                </Link>
              </li>
            )
          })}
        </ul>
      </Card>
    </section>
  )
}
