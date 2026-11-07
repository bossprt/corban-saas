import Link from 'next/link'
import { ChevronRight, Link2, Plus, Search } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { formatPhone } from '@/lib/cpf'
import { atLeast } from '@/lib/rbac'
import { CATEGORY_LABEL, formatTaxId, originText, sellerCode } from '@/lib/sellers'
import { memberEmails } from '@/lib/team.server'
import { SignupQueue } from './SignupQueue'

// Refused requests listed for the last 30 days.
function refusedSince() { return new Date(Date.now() - 30 * 86_400_000).toISOString() }
const when = (d: string) => new Date(d).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })
import { searchTerm } from '@/lib/search'
import { rejectSignup, searchSellers } from './actions'

const PAGE = 50

// Sellers: each one belongs to one seller group and is paid by that group's rule. The row opens the seller file.
// Search and pages (audit 06/11/2026): name or code in ?q= (a CPF/CNPJ is looked up by the search action, never in the URL).
export default async function SellersPage({ searchParams }: { searchParams: Promise<{ q?: string; situacao?: string; pagina?: string }> }) {
  const sp = await searchParams
  const q = searchTerm(sp.q)
  const status = sp.situacao === 'ativos' || sp.situacao === 'inativos' ? sp.situacao : ''
  const page = Math.max(1, Math.min(10_000, Number.parseInt(sp.pagina ?? '1', 10) || 1))
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Vendedores" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const since = refusedSince()
  let sellerQuery = supabase.from('commercial_sellers').select('id,code,name,tax_id,seller_category,commission_group_id,is_active,user_id,origin,is_internal', { count: 'exact' })
    .order('code').range((page - 1) * PAGE, page * PAGE - 1)
  if (q) sellerQuery = /^\d{1,9}$/.test(q) ? sellerQuery.or(`code.eq.${Number(q)},name.ilike.%${q}%`) : sellerQuery.ilike('name', `%${q}%`)
  if (status) sellerQuery = sellerQuery.eq('is_active', status === 'ativos')
  const [groups, sellers, requests, refused] = await Promise.all([
    supabase.from('commission_groups').select('id,name'),
    sellerQuery,
    // Requests from the registration links (05/11/2026), visible to admin and manager only (the database enforces it).
    canEdit ? supabase.from('seller_signup_requests').select('id,name,tax_id,commission_group_id,created_at').eq('status', 'pending').order('created_at') : Promise.resolve({ data: [] }),
    // Refused in the last 30 days: only name, document, who refused and when are kept (the data sent was erased).
    canEdit ? supabase.from('seller_signup_requests').select('id,name,tax_id,decided_by,decided_at').eq('status', 'rejected').gte('decided_at', since).order('decided_at', { ascending: false }).limit(200) : Promise.resolve({ data: [] }),
  ])
  // Only the profiles of this page, and only the documents of the pending requests (no longer every seller at once).
  const pageIds = (sellers.data ?? []).map(s => s.id)
  const reqDocs = (requests.data ?? []).map(r => r.tax_id)
  const [profiles, sameDoc] = await Promise.all([
    pageIds.length ? supabase.from('seller_profiles').select('seller_id,phone,email').in('seller_id', pageIds) : Promise.resolve({ data: [] as { seller_id: string; phone: string | null; email: string | null }[] }),
    reqDocs.length ? supabase.from('commercial_sellers').select('tax_id').in('tax_id', [...reqDocs, ...reqDocs.map(formatTaxId)]) : Promise.resolve({ data: [] as { tax_id: string | null }[] }),
  ])
  const docs = new Set((sameDoc.data ?? []).map(s => s.tax_id?.replace(/\D/g, '')).filter(Boolean))
  const groupName = new Map((groups.data ?? []).map(x => [x.id, x.name]))
  const profile = new Map((profiles.data ?? []).map(p => [p.seller_id, p]))
  const refusedRows = (refused.data ?? []) as { id: string; name: string; tax_id: string; decided_by: string | null; decided_at: string }[]
  const refusedBy = refusedRows.length ? await memberEmails(refusedRows.flatMap(r => r.decided_by ? [r.decided_by] : [])) : new Map<string, string>()
  const docLabel = (t: string) => `${t.length === 11 ? 'CPF' : 'CNPJ'} ${formatTaxId(t)}`
  const total = sellers.count ?? (sellers.data ?? []).length
  const pages = Math.max(1, Math.ceil(total / PAGE))
  const pageHref = (n: number) => `/app/cadastros/vendedores?${new URLSearchParams(Object.entries({ q: q ?? '', situacao: status, pagina: n > 1 ? String(n) : '' }).filter(([, v]) => v)).toString()}`

  return (
    <section>
      <PageHeader
        title="Vendedores"
        description={<>Cada vendedor pertence a um <Link href="/app/comercial/grupos" className="text-brand hover:text-brand-strong">grupo de vendedores</Link> e recebe pela regra desse grupo.</>}
        actions={canEdit ? <span className="flex flex-wrap gap-2">
          <ButtonLink href="/app/cadastros/vendedores/links" variant="secondary"><Link2 size={16} aria-hidden />Links de cadastro</ButtonLink>
          <ButtonLink href="/app/cadastros/vendedores/novo"><Plus size={16} aria-hidden />Novo vendedor</ButtonLink>
        </span> : undefined}
      />
      {!!(requests.data ?? []).length && (
        <Card className="mb-4">
          <CardHeader title={<span className="flex items-center gap-2">Aguardando aprovação <Badge tone="pending">{requests.data?.length}</Badge></span>} />
          <div className="mt-3">
            <SignupQueue key={(requests.data ?? []).map(r => r.id).join()} reject={rejectSignup} rows={(requests.data ?? []).map(r => ({
              id: r.id, name: r.name, alreadySeller: docs.has(r.tax_id),
              detail: `${docLabel(r.tax_id)} · Grupo: ${groupName.get(r.commission_group_id) ?? '—'} · enviado em ${when(r.created_at)}`,
            }))} />
          </div>
        </Card>
      )}
      {refusedRows.length > 0 && (
        <details className="mb-4 rounded-none border border-line bg-surface">
          <summary className="cursor-pointer px-5 py-3 text-sm font-semibold text-ink">Recusados nos últimos 30 dias <Badge tone="neutral">{refusedRows.length}</Badge></summary>
          <ul>
            {refusedRows.map(r => (
              <li key={r.id} className="border-t border-line px-5 py-2 text-[13px] text-ink-soft">
                <span className="font-semibold text-ink">{r.name}</span> · {docLabel(r.tax_id)} · recusado em {when(r.decided_at)}{r.decided_by && refusedBy.get(r.decided_by) ? ` por ${refusedBy.get(r.decided_by)}` : ''}
              </li>
            ))}
          </ul>
        </details>
      )}
      <Card>
        <CardHeader title={<span className="flex items-center gap-2">Vendedores <Badge tone="neutral">{total}</Badge></span>} />
        <form action={searchSellers} role="search" className="flex flex-wrap items-end gap-2 px-5 pt-3">
          <label className="min-w-[220px] flex-1 text-[13px] font-medium text-ink-soft">Buscar
            <input name="q" defaultValue={q ?? ''} maxLength={80} placeholder="Nome, código ou CPF/CNPJ" className="field mt-1.5" />
          </label>
          <label className="text-[13px] font-medium text-ink-soft">Situação
            <select name="situacao" defaultValue={status} className="field mt-1.5"><option value="">Todos</option><option value="ativos">Ativos</option><option value="inativos">Inativos</option></select>
          </label>
          <button className="inline-flex h-10 items-center gap-1.5 rounded-none bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Buscar</button>
          {(q || status) && <Link href="/app/cadastros/vendedores" className="h-10 px-2 text-sm leading-10 text-brand hover:underline">Limpar</Link>}
        </form>
        <ul className="mt-3">
          {!(sellers.data ?? []).length && <li className="border-t border-line px-5 py-4 text-sm text-muted">{q || status ? 'Nenhum vendedor encontrado.' : 'Nenhum vendedor cadastrado.'}</li>}
          {(sellers.data ?? []).map(s => {
            const p = profile.get(s.id)
            const incomplete = !s.is_internal && (!p?.phone || !p?.email)
            return (
              <li key={s.id}>
                <Link href={`/app/cadastros/vendedores/${s.id}`} className="group flex flex-wrap items-center gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
                  <span className="num w-12 shrink-0 font-mono text-sm text-muted">{sellerCode(s.code)}</span>
                  <span className="min-w-0 flex-1">
                    <span className="block text-sm font-semibold text-ink">{s.name}</span>
                    <span className="block text-[13px] text-ink-soft">{CATEGORY_LABEL[s.seller_category] ?? s.seller_category} · Grupo: {groupName.get(s.commission_group_id) ?? '—'}{p?.phone ? ` · ${formatPhone(p.phone)}` : ''}</span>
                  </span>
                  <span className="flex items-center gap-2">
                    {originText(s.origin, null) && <Badge tone="neutral">{originText(s.origin, null)}</Badge>}
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
        {pages > 1 && (
          <nav aria-label="Páginas" className="flex items-center justify-between gap-2 border-t border-line px-5 py-3 text-sm">
            <span className="text-ink-soft">Página {page} de {pages}</span>
            <span className="flex gap-2">
              {page > 1 && <Link href={pageHref(page - 1)} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Anterior</Link>}
              {page < pages && <Link href={pageHref(page + 1)} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Próxima</Link>}
            </span>
          </nav>
        )}
      </Card>
    </section>
  )
}
