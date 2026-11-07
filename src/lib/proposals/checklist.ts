import type { requireAppContext } from '@/lib/appContext'

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']

export const DOCUMENT_LISTS_HREF = '/app/cadastros/documentos-banco'

// Table versions whose bank and agreement have no published document list (with at least one document). A proposal on
// one of them cannot prepare its checklist (prepare_proposal_documents refuses), so it waits in "Antes da fila" until
// the list is registered: the screen says why and where to fix it (audit 06/11/2026).
export async function versionsWithoutDocumentList(supabase: Supa, versionIds: (string | null)[]): Promise<Set<string>> {
  const ids = [...new Set(versionIds.filter(Boolean))] as string[]
  if (!ids.length) return new Set()
  const { data: versions } = await supabase.from('product_table_versions').select('id,product_table_id').in('id', ids)
  const tableIds = [...new Set((versions ?? []).map(v => v.product_table_id))]
  const { data: tables } = tableIds.length ? await supabase.from('product_tables').select('id,route_id').in('id', tableIds) : { data: [] as { id: string; route_id: string }[] }
  const routeOf = new Map((tables ?? []).map(t => [t.id, t.route_id]))
  const routeIds = [...new Set((tables ?? []).map(t => t.route_id).filter(Boolean))]
  const { data: templates } = routeIds.length
    ? await supabase.from('document_checklist_templates').select('id,route_id,version,document_checklist_items(id)').eq('status', 'published').in('route_id', routeIds)
    : { data: [] as { id: string; route_id: string; version: number; document_checklist_items: { id: string }[] | null }[] }
  // The checklist comes from the latest published list of the route, as in prepare_proposal_documents.
  const latest = new Map<string, { version: number; items: number }>()
  for (const t of templates ?? []) {
    const cur = latest.get(t.route_id)
    if (!cur || t.version > cur.version) latest.set(t.route_id, { version: t.version, items: (t.document_checklist_items ?? []).length })
  }
  const ready = new Set([...latest].filter(([, t]) => t.items > 0).map(([route]) => route))
  return new Set((versions ?? []).filter(v => !ready.has(routeOf.get(v.product_table_id) ?? '')).map(v => v.id))
}
