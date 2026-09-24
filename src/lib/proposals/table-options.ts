import type { requireAppContext } from '@/lib/appContext'

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']
export type TableOption = { id: string; label: string }

// Published table versions as "Bank · Table (vN)", for the proposal forms (internal and portal).
export async function loadTableOptions(supabase: Supa): Promise<TableOption[]> {
  const { data: versions } = await supabase.from('product_table_versions').select('id,version,product_table_id').eq('status', 'published').limit(300)
  const tableIds = [...new Set((versions ?? []).map(v => v.product_table_id))]
  const { data: tables } = tableIds.length ? await supabase.from('product_tables').select('id,name,code,route_id').in('id', tableIds) : { data: [] as { id: string; name: string; code: string; route_id: string }[] }
  const routeIds = [...new Set((tables ?? []).map(t => t.route_id))]
  const { data: routes } = routeIds.length ? await supabase.from('organization_product_routes').select('id,org_bank_id').in('id', routeIds) : { data: [] as { id: string; org_bank_id: string | null }[] }
  const bankIds = [...new Set((routes ?? []).map(r => r.org_bank_id).filter(Boolean))] as string[]
  const { data: banks } = bankIds.length ? await supabase.from('organization_banks').select('id,name').in('id', bankIds) : { data: [] as { id: string; name: string }[] }
  const bankOfRoute = new Map((routes ?? []).map(r => [r.id, (banks ?? []).find(b => b.id === r.org_bank_id)?.name ?? '']))
  const tableLabel = new Map((tables ?? []).map(t => [t.id, `${bankOfRoute.get(t.route_id) || 'Banco'} · ${t.name}`]))
  return (versions ?? []).map(v => ({ id: v.id, label: `${tableLabel.get(v.product_table_id) ?? 'Tabela'} (v${v.version})` })).sort((a, b) => a.label.localeCompare(b.label))
}
