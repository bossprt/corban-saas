import { fetchAll } from '@/lib/fetchAll'

// The commission tables search (owner decision 25/09/2026), shared by the search screen and the "Exportar planilha" of
// the search, so the export always holds exactly the tables the filters show.
export type TableFilters = { banco: string; convenio: string; nome: string; promotora: string; situacao: string; vigencia: string; tipo: string; codigo: string }

export function readTableFilters(get: (k: string) => string): TableFilters {
  return {
    banco: get('banco'), convenio: get('convenio'), nome: get('nome').trim(), promotora: get('promotora'), situacao: get('situacao') || 'ativas',
    vigencia: get('vigencia') || 'atuais', tipo: get('tipo'), codigo: get('codigo').trim(),
  }
}

export type TableVersion = { id: string; product_table_id: string; version: number; status: string; effective_from: string | null; effective_until: string | null; published_at: string | null; metadata: unknown }
type Named = { id: string; name: string }
type Route = { id: string; org_bank_id: string; org_agreement_id: string; org_provider_id: string | null }
type Table = { id: string; route_id: string; code: string | null; name: string; status: string }

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- the scoped Supabase client is untyped in this codebase
export async function searchTables(supabase: { from: (table: string) => any }, f: TableFilters) {
  const [banks, agreements, providers, types, routes, tables, versions, conditions] = await Promise.all([
    supabase.from('organization_banks').select('id,name').order('name'),
    supabase.from('organization_agreements').select('id,name').order('name'),
    supabase.from('organization_providers').select('id,name').order('name'),
    supabase.from('contract_types').select('id,name').order('sort_order'),
    supabase.from('organization_product_routes').select('id,org_bank_id,org_agreement_id,org_provider_id').not('org_bank_id', 'is', null),
    supabase.from('product_tables').select('id,route_id,code,name,status').order('name'),
    fetchAll<TableVersion>((a, b) => supabase.from('product_table_versions').select('id,product_table_id,version,status,effective_from,effective_until,published_at,metadata').order('version', { ascending: false }).order('id').range(a, b)),
    fetchAll<{ product_table_version_id: string; contract_type_id: string }>((a, b) => supabase.from('commercial_conditions').select('product_table_version_id,contract_type_id').order('id').range(a, b)),
  ])
  const route = new Map(((routes.data ?? []) as Route[]).map(r => [r.id, r]))
  const byTable = new Map<string, TableVersion[]>()
  for (const v of versions) byTable.set(v.product_table_id, [...(byTable.get(v.product_table_id) ?? []), v])
  const lines = new Map<string, number>(), typesOf = new Map<string, Set<string>>()
  for (const c of conditions) {
    lines.set(c.product_table_version_id, (lines.get(c.product_table_version_id) ?? 0) + 1)
    typesOf.set(c.product_table_version_id, (typesOf.get(c.product_table_version_id) ?? new Set()).add(c.contract_type_id))
  }

  const rows = ((tables.data ?? []) as Table[]).filter(t => route.has(t.route_id)).map(t => {
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

  return {
    rows,
    banks: (banks.data ?? []) as Named[], agreements: (agreements.data ?? []) as Named[],
    providers: (providers.data ?? []) as Named[], types: (types.data ?? []) as Named[],
  }
}
