import Link from 'next/link'
import { CalendarDays, CircleDollarSign, Download, Eye, Plus, Search, Sparkles } from 'lucide-react'
import { Badge, ButtonLink, Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { PAGE_SIZES, pageSize } from '@/lib/commission/tableValues'
import { fetchAll } from '@/lib/fetchAll'

type SP = Record<string, string | string[] | undefined>
const one = (v: string | string[] | undefined) => (typeof v === 'string' ? v : '')
const lbl = 'text-[13px] font-medium text-ink-soft'
const iconBtn = 'inline-flex size-8 items-center justify-center rounded-md text-brand hover:bg-brand-soft'
// Vigência dates are calendar days stored at 00:00 UTC: shown in UTC so 01/09 never becomes 31/08.
const dateBr = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'UTC' }) : '—')

// Commission tables: a search screen (owner decision 25/09/2026). Filters, a paged result and one row per table with
// its actions: 📅 vigências, $ commission, 👁 name. The lines of a table open on its own page.
export default async function TablesSearchPage({ searchParams }: { searchParams: Promise<SP> }) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Tabelas" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const sp = await searchParams
  const f = { banco: one(sp.banco), convenio: one(sp.convenio), nome: one(sp.nome).trim(), promotora: one(sp.promotora), situacao: one(sp.situacao) || 'ativas',
    vigencia: one(sp.vigencia) || 'atuais', tipo: one(sp.tipo), codigo: one(sp.codigo).trim() }
  const size = pageSize(one(sp.n), 25)

  const [banks, agreements, providers, types, routes, tables, versions, conditions] = await Promise.all([
    supabase.from('organization_banks').select('id,name').order('name'),
    supabase.from('organization_agreements').select('id,name').order('name'),
    supabase.from('organization_providers').select('id,name').order('name'),
    supabase.from('contract_types').select('id,name').order('sort_order'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_agreement_id,org_provider_id').not('org_bank_id', 'is', null),
    supabase.from('product_tables').select('id,route_id,code,name,status').order('name'),
    fetchAll<{ id: string; product_table_id: string; version: number; status: string; effective_from: string | null; published_at: string | null }>((a, b) => supabase.from('product_table_versions').select('id,product_table_id,version,status,effective_from,published_at').order('version', { ascending: false }).order('id').range(a, b)),
    fetchAll<{ product_table_version_id: string; contract_type_id: string }>((a, b) => supabase.from('commercial_conditions').select('product_table_version_id,contract_type_id').order('id').range(a, b)),
  ])
  const name = (rows: { id: string; name: string }[] | null) => new Map((rows ?? []).map(r => [r.id, r.name]))
  const bankN = name(banks.data), agrN = name(agreements.data), provN = name(providers.data)
  const route = new Map((routes.data ?? []).map(r => [r.id, r]))
  const byTable = new Map<string, typeof versions>()
  for (const v of versions) byTable.set(v.product_table_id, [...(byTable.get(v.product_table_id) ?? []), v])
  const lines = new Map<string, number>(), typesOf = new Map<string, Set<string>>()
  for (const c of conditions) {
    lines.set(c.product_table_version_id, (lines.get(c.product_table_version_id) ?? 0) + 1)
    typesOf.set(c.product_table_version_id, (typesOf.get(c.product_table_version_id) ?? new Set()).add(c.contract_type_id))
  }

  const rows = (tables.data ?? []).filter(t => route.has(t.route_id)).map(t => {
    const r = route.get(t.route_id)!
    const vs = byTable.get(t.id) ?? []
    const current = vs.find(v => v.status === 'published')
    const draft = vs.find(v => v.status === 'draft')
    const shown = current ?? draft ?? vs[0]
    return { t, r, current, draft, shown, lines: shown ? lines.get(shown.id) ?? 0 : 0, types: shown ? typesOf.get(shown.id) ?? new Set<string>() : new Set<string>() }
  }).filter(x =>
    (!f.banco || x.r.org_bank_id === f.banco) && (!f.convenio || x.r.org_agreement_id === f.convenio)
    && (!f.promotora || (f.promotora === 'propria' ? !x.r.org_provider_id : x.r.org_provider_id === f.promotora))
    && (f.situacao === 'todas' || (f.situacao === 'inativas' ? x.t.status !== 'active' : x.t.status === 'active'))
    && (f.vigencia === 'todas' || (f.vigencia === 'rascunho' ? !!x.draft : !!x.current))
    && (!f.tipo || x.types.has(f.tipo))
    && (!f.nome || x.t.name.toLowerCase().includes(f.nome.toLowerCase()))
    && (!f.codigo || (x.t.code ?? '').toLowerCase().includes(f.codigo.toLowerCase())))
  const total = rows.length, pages = Math.max(1, Math.ceil(total / size))
  const page = Math.min(Math.max(1, Number(one(sp.p)) || 1), pages)
  const shown = rows.slice((page - 1) * size, page * size)
  const qs = (patch: Record<string, string | number>) => {
    const q = new URLSearchParams(Object.entries({ ...f, n: size, p: page, ...patch }).filter(([, v]) => v !== '' && v !== undefined).map(([k, v]) => [k, String(v)]))
    return `/app/comercial/tabelas?${q.toString()}`
  }

  return (
    <section>
      <PageHeader title="Tabelas" description="Tabelas de comissão dos bancos: o que a empresa recebe e o que cada grupo de vendedores ganha."
        actions={canEdit ? <>
          <ButtonLink href="/app/comercial/importacao-inteligente" variant="secondary"><Sparkles size={16} aria-hidden />Importar planilha</ButtonLink>
          <ButtonLink href="/api/comercial/modelo" variant="secondary"><Download size={16} aria-hidden />Baixar modelo</ButtonLink>
          <ButtonLink href="/app/comercial/tabelas/nova"><Plus size={16} aria-hidden />Nova tabela</ButtonLink>
        </> : undefined} />

      <Card className="mb-4 p-5">
        <form className="grid gap-3 md:grid-cols-4" role="search" aria-label="Pesquisar tabelas">
          <label className={lbl}>Banco<select name="banco" defaultValue={f.banco} className="field mt-1.5"><option value="">Todos</option>{(banks.data ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          <label className={lbl}>Convênio<select name="convenio" defaultValue={f.convenio} className="field mt-1.5"><option value="">Todos</option>{(agreements.data ?? []).map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
          <label className={lbl}>Nome da tabela<input name="nome" defaultValue={f.nome} className="field mt-1.5" /></label>
          <label className={lbl}>Promotora parceira<select name="promotora" defaultValue={f.promotora} className="field mt-1.5"><option value="">Todas</option><option value="propria">Produção própria</option>{(providers.data ?? []).map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <label className={lbl}>Situação<select name="situacao" defaultValue={f.situacao} className="field mt-1.5"><option value="ativas">Ativas</option><option value="inativas">Inativas</option><option value="todas">Todas</option></select></label>
          <label className={lbl}>Vigência<select name="vigencia" defaultValue={f.vigencia} className="field mt-1.5"><option value="atuais">Com vigência atual</option><option value="rascunho">Com rascunho</option><option value="todas">Todas</option></select></label>
          <label className={lbl}>Tipo de contrato<select name="tipo" defaultValue={f.tipo} className="field mt-1.5"><option value="">Todos</option>{(types.data ?? []).map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select></label>
          <label className={lbl}>Código no banco<input name="codigo" defaultValue={f.codigo} className="field mt-1.5 font-mono" /></label>
          <input type="hidden" name="n" value={size} />
          <div className="flex items-end gap-2 md:col-span-4">
            <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong"><Search size={15} aria-hidden />Pesquisar</button>
            <Link href="/app/comercial/tabelas" className="inline-flex h-10 items-center rounded-[10px] border border-line px-4 text-sm text-ink-soft hover:bg-surface-muted">Limpar</Link>
          </div>
        </form>
      </Card>

      <Card>
        <div className="flex flex-wrap items-center justify-between gap-3 px-5 pt-4 text-sm text-ink-soft">
          <span><strong className="text-ink">{total}</strong> tabela(s)</span>
          <span className="flex items-center gap-1.5">Exibir {PAGE_SIZES.map(n => (
            <Link key={n} href={qs({ n, p: 1 })} aria-current={n === size ? 'true' : undefined}
              className={`rounded-md px-2 py-1 ${n === size ? 'bg-brand-soft font-semibold text-brand' : 'hover:bg-surface-muted'}`}>{n}</Link>
          ))} por página</span>
        </div>
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[880px] text-left text-[13px]">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-4 py-2 font-medium">Tabela</th><th className="px-3 py-2 font-medium">Banco</th><th className="px-3 py-2 font-medium">Convênio</th><th className="px-3 py-2 font-medium">Promotora</th>
                <th className="px-3 py-2 font-medium">Vigência</th><th className="px-3 py-2 text-right font-medium">Linhas</th><th className="px-3 py-2 text-right font-medium">Ações</th></tr>
            </thead>
            <tbody>
              {shown.map(x => (
                <tr key={x.t.id} className="border-t border-line align-top hover:bg-surface-muted/60">
                  <td className="px-4 py-2.5">
                    <Link href={`/app/comercial/tabelas/${x.t.id}`} className="font-medium text-ink hover:text-brand">{x.t.name}</Link>
                    {x.t.code && !x.t.code.startsWith('t-') && <div className="font-mono text-xs text-muted">{x.t.code}</div>}
                    {x.t.status !== 'active' && <Badge tone="neutral" className="ml-1">Inativa</Badge>}
                  </td>
                  <td className="px-3 py-2.5">{bankN.get(x.r.org_bank_id) ?? '—'}</td>
                  <td className="px-3 py-2.5">{agrN.get(x.r.org_agreement_id) ?? '—'}</td>
                  <td className="px-3 py-2.5">{x.r.org_provider_id ? provN.get(x.r.org_provider_id) ?? '—' : 'Própria'}</td>
                  <td className="px-3 py-2.5">
                    {x.current ? <span className="text-ink">v{x.current.version} desde {dateBr(x.current.effective_from ?? x.current.published_at)}</span> : <span className="text-muted">Sem vigência</span>}
                    {x.draft && <Badge tone="pending" className="ml-1.5">Rascunho v{x.draft.version}</Badge>}
                  </td>
                  <td className="num px-3 py-2.5 text-right">{x.lines}</td>
                  <td className="px-3 py-1.5">
                    <span className="flex justify-end gap-0.5">
                      <Link href={`/app/comercial/tabelas/${x.t.id}#vigencias`} className={iconBtn} title="Vigências" aria-label={`Vigências de ${x.t.name}`}><CalendarDays size={16} aria-hidden /></Link>
                      <Link href={`/app/comercial/tabelas/${x.t.id}#comissao`} className={iconBtn} title="Comissão" aria-label={`Comissão de ${x.t.name}`}><CircleDollarSign size={16} aria-hidden /></Link>
                      <Link href={`/app/comercial/tabelas/${x.t.id}#nome`} className={iconBtn} title="Nome da tabela" aria-label={`Nome de ${x.t.name}`}><Eye size={16} aria-hidden /></Link>
                    </span>
                  </td>
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={7} className="px-4 py-6 text-center text-muted">Nenhuma tabela com esses filtros.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm text-ink-soft">
          <span>{total ? `${(page - 1) * size + 1}–${Math.min(page * size, total)} de ${total}` : '0 de 0'}</span>
          <span className="flex items-center gap-1">
            <Link href={qs({ p: Math.max(1, page - 1) })} aria-disabled={page === 1} className={`rounded-md border border-line px-2.5 py-1 ${page === 1 ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Anterior</Link>
            {Array.from({ length: pages }, (_, i) => i + 1).filter(n => n === 1 || n === pages || Math.abs(n - page) <= 2).map((n, i, arr) => (
              <span key={n} className="flex items-center gap-1">
                {i > 0 && n - arr[i - 1] > 1 && <span className="px-1 text-muted">…</span>}
                <Link href={qs({ p: n })} aria-current={n === page ? 'page' : undefined} className={`rounded-md px-2.5 py-1 ${n === page ? 'bg-brand font-semibold text-white' : 'border border-line hover:bg-surface-muted'}`}>{n}</Link>
              </span>
            ))}
            <Link href={qs({ p: Math.min(pages, page + 1) })} aria-disabled={page === pages} className={`rounded-md border border-line px-2.5 py-1 ${page === pages ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Próxima</Link>
          </span>
        </div>
      </Card>
    </section>
  )
}
