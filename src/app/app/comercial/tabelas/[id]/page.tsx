import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft, CircleDollarSign, CopyPlus, Search } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import { PAGE_SIZES, pageSize, rangeText, termText, valueText, VERSION_STATUS } from '@/lib/commission/tableValues'
import { fetchAll } from '@/lib/fetchAll'
import { cloneVersion, publishVersion, renameTable } from '../actions'

type SP = Record<string, string | string[] | undefined>
const one = (v: string | string[] | undefined) => (typeof v === 'string' ? v : '')
const lbl = 'text-[13px] font-medium text-ink-soft'
// Vigência dates are calendar days stored at 00:00 UTC: shown in UTC so 01/09 never becomes 31/08.
const dateBr = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'UTC' }) : '—')
const TONE: Record<string, 'received' | 'pending' | 'neutral'> = { published: 'received', draft: 'pending' }

// One commission table: its name, its "vigências" (versions) and the lines of the chosen one, shown one party at a
// time (the company or one seller group) so 121-line tables stay readable.
export default async function TablePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<SP> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return <section><PageHeader title="Tabela" /><Card className="p-5 text-sm text-ink-soft">Sem permissão.</Card></section>
  const canEdit = atLeast(membership.role, 'manager')
  const seeCommission = canViewCommission(membership.role)
  const sp = await searchParams

  const [{ data: table }, { data: versions }, { data: types }, { data: components }, { data: groups }, { data: rules }] = await Promise.all([
    supabase.from('product_tables').select('id,route_id,code,name,status').eq('id', id).maybeSingle(),
    supabase.from('product_table_versions').select('id,version,status,effective_from,effective_until,published_at,created_at').eq('product_table_id', id).order('version', { ascending: false }),
    supabase.from('contract_types').select('id,name'),
    supabase.from('commission_component_types').select('id,tech_key,name,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('group_id,version,own_production').order('version', { ascending: false }),
  ])
  if (!table) notFound()
  const { data: route } = await supabase.from('organization_product_routes').select('org_bank_id,org_agreement_id,org_provider_id,production_origin').eq('id', table.route_id).maybeSingle()
  const [{ data: bank }, { data: agreement }, { data: provider }] = await Promise.all([
    supabase.from('organization_banks').select('name').eq('id', route?.org_bank_id ?? '').maybeSingle(),
    supabase.from('organization_agreements').select('name').eq('id', route?.org_agreement_id ?? '').maybeSingle(),
    route?.org_provider_id ? supabase.from('organization_providers').select('name').eq('id', route.org_provider_id).maybeSingle() : Promise.resolve({ data: null }),
  ])

  const vs = versions ?? []
  const draft = vs.find(v => v.status === 'draft')
  const selected = vs.find(v => v.id === one(sp.v)) ?? vs.find(v => v.status === 'published') ?? vs[0]
  const own = new Map<string, boolean>()
  for (const r of rules ?? []) if (!own.has(r.group_id)) own.set(r.group_id, r.own_production)
  const payGroups = (groups ?? []).filter(g => g.is_active && !own.get(g.id))
  const view = one(sp.ver) || 'empresa'
  const typeName = new Map((types ?? []).map(t => [t.id, t.name]))

  type Line = { id: string; contract_type_id: string; term: number; term_min: number | null; term_max: number | null; amount_min: string | null; amount_max: string | null; coefficient: string | null; rate: string | null }
  const conditions = selected ? await fetchAll<Line>((a, b) => supabase.from('commercial_conditions').select('id,contract_type_id,term,term_min,term_max,amount_min,amount_max,coefficient,rate')
    .eq('product_table_version_id', selected.id).order('term_min').order('term').order('id').range(a, b)) : []
  // Values are read by vigência (joined through the line), page by page: a big table has thousands of them.
  const [comp, gv] = selected ? await Promise.all([
    fetchAll<{ condition_id: string; component_type_id: string; value_kind: string; received_value: string; calculation_base: string | null }>((a, b) => supabase.from('commercial_condition_components')
      .select('condition_id,component_type_id,value_kind,received_value,calculation_base,commercial_conditions!inner(product_table_version_id)').eq('commercial_conditions.product_table_version_id', selected.id).order('id').range(a, b)),
    fetchAll<{ condition_id: string; group_id: string; component_type_id: string; value_kind: string; value: string }>((a, b) => supabase.from('commercial_condition_group_values')
      .select('condition_id,group_id,component_type_id,value_kind,value,commercial_conditions!inner(product_table_version_id)').eq('commercial_conditions.product_table_version_id', selected.id)
      .order('condition_id').order('group_id').order('component_type_id').range(a, b)),
  ]) : [[], []]
  const companyOf = new Map<string, { value_kind: string; received_value: string; calculation_base: string | null }>()
  for (const c of comp ?? []) companyOf.set(`${c.condition_id}:${c.component_type_id}`, c)
  const groupOf = new Map<string, { value_kind: string; value: string }>()
  for (const g of gv ?? []) groupOf.set(`${g.condition_id}:${g.group_id}:${g.component_type_id}`, g)
  const baseOf = new Map<string, string | null>()
  for (const c of comp ?? []) if (!baseOf.get(c.condition_id)) baseOf.set(c.condition_id, c.calculation_base)
  // Only the commission types that appear somewhere in this vigência get a column.
  const usedTypes = (components ?? []).filter(t => comp.some(c => c.component_type_id === t.id) || gv.some(g => g.component_type_id === t.id))

  const tipo = one(sp.tipo), prazo = Number(one(sp.prazo)) || 0
  const filtered = conditions.filter(c => (!tipo || c.contract_type_id === tipo) && (!prazo || ((c.term_min ?? c.term) <= prazo && prazo <= (c.term_max ?? c.term))))
  const size = pageSize(one(sp.n), 25), pages = Math.max(1, Math.ceil(filtered.length / size))
  const page = Math.min(Math.max(1, Number(one(sp.p)) || 1), pages)
  const rows = filtered.slice((page - 1) * size, page * size)
  const usedTypeIds = new Set(conditions.map(c => c.contract_type_id))
  const qs = (patch: Record<string, string | number>) => {
    const q = new URLSearchParams(Object.entries({ v: selected?.id ?? '', ver: view, tipo, prazo: prazo || '', n: size, p: page, ...patch })
      .filter(([, x]) => x !== '' && x !== undefined).map(([k, x]) => [k, String(x)]))
    return `/app/comercial/tabelas/${id}?${q.toString()}#comissao`
  }
  const views = [{ key: 'empresa', label: 'Empresa' }, ...payGroups.map(g => ({ key: g.id, label: g.name })), { key: 'resumo', label: 'Resumo (À Vista)' }]
  const upfront = (components ?? []).find(t => t.tech_key === 'upfront')
  const cell = (conditionId: string, party: string, typeId: string) => {
    if (party === 'empresa') { const c = companyOf.get(`${conditionId}:${typeId}`); return c ? valueText(c.value_kind, c.received_value) : '' }
    const g = groupOf.get(`${conditionId}:${party}:${typeId}`); return g ? valueText(g.value_kind, g.value) : ''
  }

  return (
    <section>
      <Link href="/app/comercial/tabelas" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Tabelas</Link>
      <PageHeader title={table.name} description={<span className="flex flex-wrap items-center gap-2">
        <span>{bank?.name ?? 'Banco'} · {agreement?.name ?? 'Convênio'} · {provider?.name ? `por ${provider.name}` : 'produção própria'}</span>
        {table.code && !table.code.startsWith('t-') && <span className="font-mono text-xs">{table.code}</span>}
        {table.status !== 'active' && <Badge tone="neutral">Inativa</Badge>}
      </span>} />

      <div className="grid gap-4 lg:grid-cols-[1.4fr_1fr]">
        <Card id="vigencias">
          <CardHeader title="Vigências" action={canEdit && selected && !draft ? (
            <form action={cloneVersion}><input type="hidden" name="table_id" value={id} /><input type="hidden" name="version_id" value={selected.id} />
              <SubmitButton className="inline-flex h-9 items-center gap-1.5 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted" pendingText="Criando..."><CopyPlus size={15} aria-hidden className="mr-1 inline" />Nova vigência a partir da v{selected.version}</SubmitButton></form>
          ) : undefined} />
          <ul className="mt-3">
            {vs.map(v => (
              <li key={v.id} className={`flex flex-wrap items-center justify-between gap-2 border-t border-line px-5 py-2.5 text-sm ${v.id === selected?.id ? 'bg-brand-soft/40' : ''}`}>
                <Link href={`/app/comercial/tabelas/${id}?v=${v.id}#comissao`} className="flex items-center gap-2 text-ink hover:text-brand">
                  <span className="font-semibold">v{v.version}</span><Badge tone={TONE[v.status] ?? 'neutral'}>{VERSION_STATUS[v.status] ?? v.status}</Badge>
                  <span className="text-xs text-muted">{v.status === 'draft' ? `criada em ${dateBr(v.created_at)}` : `de ${dateBr(v.effective_from ?? v.published_at)}${v.effective_until ? ` até ${dateBr(v.effective_until)}` : ''}`}</span>
                </Link>
                {v.status === 'draft' && canEdit && (
                  <form action={publishVersion}><input type="hidden" name="table_id" value={id} /><input type="hidden" name="version_id" value={v.id} />
                    <SubmitButton className="h-8 rounded-md bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong" pendingText="Publicando...">Publicar</SubmitButton></form>
                )}
              </li>
            ))}
            {!vs.length && <li className="border-t border-line px-5 py-3 text-sm text-muted">Nenhuma vigência.</li>}
          </ul>
        </Card>

        <Card id="nome">
          <CardHeader title="Nome da tabela" />
          {canEdit ? (
            <form action={renameTable} className="flex flex-wrap items-end gap-2 px-5 pb-5 pt-3">
              <input type="hidden" name="table_id" value={id} />
              <label className={`${lbl} flex-1`}>Nome<input required name="name" defaultValue={table.name} maxLength={160} className="field mt-1.5" /></label>
              <SubmitButton className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted" pendingText="Salvando...">Salvar nome</SubmitButton>
            </form>
          ) : <p className="px-5 pb-5 pt-3 text-sm text-ink">{table.name}</p>}
        </Card>
      </div>

      {seeCommission && <Card id="comissao" className="mt-4">
        <CardHeader title={<span className="flex flex-wrap items-center gap-2">Comissão {selected && <><span className="text-sm font-normal text-muted">v{selected.version}</span><Badge tone={TONE[selected.status] ?? 'neutral'}>{VERSION_STATUS[selected.status]}</Badge></>}</span>}
          action={selected?.status !== 'draft' && canEdit ? <span className="text-xs text-muted">Para alterar, crie uma nova vigência a partir desta.</span> : undefined} />
        <div className="flex flex-wrap gap-1.5 px-5 pt-3" role="tablist" aria-label="Ver comissão de">
          {views.map(x => <Link key={x.key} href={qs({ ver: x.key, p: 1 })} role="tab" aria-selected={view === x.key}
            className={`rounded-full border px-3 py-1 text-[13px] ${view === x.key ? 'border-brand bg-brand text-white' : 'border-line text-ink-soft hover:bg-surface-muted'}`}>{x.label}</Link>)}
        </div>
        <form className="flex flex-wrap items-end gap-2 px-5 pt-3">
          {selected && <input type="hidden" name="v" value={selected.id} />}<input type="hidden" name="ver" value={view} /><input type="hidden" name="n" value={size} />
          <label className={lbl}>Tipo de contrato<select name="tipo" defaultValue={tipo} className="field mt-1.5 min-w-44"><option value="">Todos</option>{[...usedTypeIds].map(t => <option key={t} value={t}>{typeName.get(t) ?? 'Tipo'}</option>)}</select></label>
          <label className={lbl}>Prazo (meses)<input name="prazo" defaultValue={prazo || ''} inputMode="numeric" className="field mt-1.5 w-28" /></label>
          <button className="inline-flex h-10 items-center gap-1.5 rounded-[10px] border border-line-strong px-3 text-sm text-ink hover:bg-surface-muted"><Search size={15} aria-hidden />Filtrar</button>
        </form>

        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-[13px]">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr>
                <th className="px-4 py-2 font-medium">Tipo</th><th className="px-3 py-2 font-medium">Prazo</th><th className="px-3 py-2 font-medium">Valor da operação</th>
                <th className="px-3 py-2 text-right font-medium">Taxa / coef.</th><th className="px-3 py-2 font-medium">Base</th>
                {view === 'resumo'
                  ? [{ id: 'empresa', name: 'Empresa' }, ...payGroups].map(p => <th key={p.id} className="px-3 py-2 text-right font-medium">{p.name}</th>)
                  : usedTypes.map(t => <th key={t.id} className="px-3 py-2 text-right font-medium">{t.name}</th>)}
                {selected?.status === 'draft' && canEdit && <th className="px-3 py-2" />}
              </tr>
            </thead>
            <tbody>
              {rows.map(c => (
                <tr key={c.id} className="border-t border-line hover:bg-surface-muted/60">
                  <td className="px-4 py-2">{typeName.get(c.contract_type_id) ?? '—'}</td>
                  <td className="num px-3 py-2">{termText(c.term_min, c.term_max, c.term)}</td>
                  <td className="num px-3 py-2 text-ink-soft">{rangeText(c.amount_min, c.amount_max)}</td>
                  <td className="num px-3 py-2 text-right">{c.rate ?? c.coefficient ?? '—'}</td>
                  <td className="px-3 py-2 text-xs text-muted">{baseOf.get(c.id) ?? '—'}</td>
                  {view === 'resumo'
                    ? [{ id: 'empresa' }, ...payGroups].map(p => <td key={p.id} className="num px-3 py-2 text-right">{upfront ? cell(c.id, p.id, upfront.id) || '—' : '—'}</td>)
                    : usedTypes.map(t => <td key={t.id} className="num px-3 py-2 text-right">{cell(c.id, view, t.id) || <span className="text-muted">—</span>}</td>)}
                  {selected?.status === 'draft' && canEdit && <td className="px-3 py-1.5 text-right">
                    <Link href={`/app/comercial/tabelas/${id}/linha/${c.id}`} className="inline-flex size-8 items-center justify-center rounded-md text-brand hover:bg-brand-soft" title="Alterar comissão" aria-label="Alterar comissão"><CircleDollarSign size={16} aria-hidden /></Link>
                  </td>}
                </tr>
              ))}
              {!rows.length && <tr><td colSpan={20} className="px-4 py-6 text-center text-muted">Nenhuma linha {filtered.length !== conditions.length ? 'com esses filtros' : 'nesta vigência'}.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 px-5 py-3 text-sm text-ink-soft">
          <span>{filtered.length ? `${(page - 1) * size + 1}–${Math.min(page * size, filtered.length)} de ${filtered.length} linha(s)` : '0 linhas'}</span>
          <span className="flex items-center gap-1.5">Exibir {PAGE_SIZES.map(n => <Link key={n} href={qs({ n, p: 1 })} className={`rounded-md px-2 py-1 ${n === size ? 'bg-brand-soft font-semibold text-brand' : 'hover:bg-surface-muted'}`}>{n}</Link>)}
            <Link href={qs({ p: Math.max(1, page - 1) })} className={`ml-2 rounded-md border border-line px-2.5 py-1 ${page === 1 ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Anterior</Link>
            <span className="px-1">{page}/{pages}</span>
            <Link href={qs({ p: Math.min(pages, page + 1) })} className={`rounded-md border border-line px-2.5 py-1 ${page === pages ? 'pointer-events-none opacity-40' : 'hover:bg-surface-muted'}`}>Próxima</Link>
          </span>
        </div>
      </Card>}
    </section>
  )
}
