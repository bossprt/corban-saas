import type { NextRequest } from 'next/server'
import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import { fetchAll } from '@/lib/fetchAll'
import { baseLabel, fileSlug, SHEET_LINE_COLUMNS, SHEET_TAIL_COLUMNS, sheetDate, sheetValue, valueColumns } from '@/lib/commission/tableSheet'
import { decimalBr } from '@/lib/commission/tableValues'

export const dynamic = 'force-dynamic'

type Line = { id: string; contract_type_id: string; term: number; term_min: number | null; term_max: number | null; amount_min: string | null; coefficient: string | null; rate: string | null; tax_pct: string }

// "Exportar planilha" of one vigência, in the import layout (ADR-0037): the owner changes the tax (or anything else)
// in Excel and imports it back, which creates a new draft vigência to publish. Coefficient goes in "Coeficiente" (not
// "Fator"), so importing it back never creates daily factors.
export async function GET(req: NextRequest, ctx: RouteContext<'/api/comercial/tabelas/[id]/exportar'>) {
  const { id } = await ctx.params
  const versionId = req.nextUrl.searchParams.get('v') ?? ''
  if (!isUuid(id) || !isUuid(versionId)) return new Response('Pedido inválido', { status: 400 })
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor') || !canViewCommission(membership.role)) return new Response('Sem permissão', { status: 403 })

  const [{ data: table }, { data: version }, { data: types }, { data: components }, { data: groups }, { data: rules }] = await Promise.all([
    supabase.from('product_tables').select('id,route_id,code,name').eq('id', id).maybeSingle(),
    supabase.from('product_table_versions').select('id,version,product_table_id,effective_from,effective_until,metadata').eq('id', versionId).maybeSingle(),
    supabase.from('contract_types').select('id,name'),
    supabase.from('commission_component_types').select('id,tech_key,name,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active', true).order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('group_id,version,own_production').order('version', { ascending: false }),
  ])
  if (!table || !version || version.product_table_id !== id) return new Response('Tabela não encontrada', { status: 404 })
  const { data: route } = await supabase.from('organization_product_routes').select('org_bank_id,org_agreement_id').eq('id', table.route_id).maybeSingle()
  const [{ data: bank }, { data: agreement }] = await Promise.all([
    supabase.from('organization_banks').select('name').eq('id', route?.org_bank_id ?? '').maybeSingle(),
    supabase.from('organization_agreements').select('name').eq('id', route?.org_agreement_id ?? '').maybeSingle(),
  ])

  const lines = await fetchAll<Line>((a, b) => supabase.from('commercial_conditions').select('id,contract_type_id,term,term_min,term_max,amount_min,coefficient,rate,tax_pct')
    .eq('product_table_version_id', version.id).order('term_min').order('term').order('id').range(a, b))
  // The import has no amount ranges: exporting such a table would lose them when imported back.
  if (lines.some(l => l.amount_min !== null)) return new Response('Esta tabela tem faixas de valor da operação e ainda não pode ser exportada.', { status: 409 })
  const [comp, gv] = await Promise.all([
    fetchAll<{ condition_id: string; component_type_id: string; value_kind: string; received_value: string; calculation_base: string | null }>((a, b) => supabase.from('commercial_condition_components')
      .select('condition_id,component_type_id,value_kind,received_value,calculation_base,commercial_conditions!inner(product_table_version_id)').eq('commercial_conditions.product_table_version_id', version.id).order('id').range(a, b)),
    fetchAll<{ condition_id: string; group_id: string; component_type_id: string; value_kind: string; value: string }>((a, b) => supabase.from('commercial_condition_group_values')
      .select('condition_id,group_id,component_type_id,value_kind,value,commercial_conditions!inner(product_table_version_id)').eq('commercial_conditions.product_table_version_id', version.id)
      .order('condition_id').order('group_id').order('component_type_id').range(a, b)),
  ])

  const own = new Map<string, boolean>()
  for (const r of rules ?? []) if (!own.has(r.group_id)) own.set(r.group_id, r.own_production)
  const payGroups = (groups ?? []).filter(g => !own.get(g.id))
  const typeName = new Map((types ?? []).map(t => [t.id, t.name]))
  const companyOf = new Map(comp.map(c => [`${c.condition_id}:${c.component_type_id}`, c]))
  const groupOf = new Map(gv.map(g => [`${g.condition_id}:${g.group_id}:${g.component_type_id}`, g]))
  const baseOf = new Map<string, string>()
  for (const c of comp) if (c.calculation_base && !baseOf.has(c.condition_id)) baseOf.set(c.condition_id, c.calculation_base)
  const types2 = components ?? []
  const externalCode = String((version.metadata as { external_table_code?: string } | null)?.external_table_code ?? (table.code?.startsWith('t-') ? '' : table.code ?? ''))

  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('Tabelas')
  const columns = [...SHEET_LINE_COLUMNS, 'Coeficiente', 'Taxa a.m. (%)', ...SHEET_TAIL_COLUMNS, ...valueColumns(types2, payGroups)]
  ws.addRow(columns)
  for (const l of lines) {
    ws.addRow([
      bank?.name ?? '', agreement?.name ?? '', table.name, externalCode,
      sheetDate(version.effective_from), sheetDate(version.effective_until), typeName.get(l.contract_type_id) ?? '',
      l.term_min ?? l.term, l.term_max ?? l.term,
      l.coefficient === null ? '' : decimalBr(l.coefficient), l.rate === null ? '' : decimalBr(l.rate),
      baseLabel(baseOf.get(l.id)), Number(l.tax_pct) ? decimalBr(l.tax_pct) : '0',
      ...types2.map(t => { const c = companyOf.get(`${l.id}:${t.id}`); return sheetValue(c?.value_kind, c?.received_value) }),
      ...payGroups.flatMap(g => types2.map(t => { const v = groupOf.get(`${l.id}:${g.id}:${t.id}`); return sheetValue(v?.value_kind, v?.value) })),
    ])
  }
  ws.views = [{ state: 'frozen', ySplit: 1 }]
  ws.getRow(1).font = { bold: true }
  ws.columns = columns.map((h, i) => ({ key: String(i), width: Math.min(42, Math.max(12, h.length + 2)) }))

  const buffer = await wb.xlsx.writeBuffer()
  return new Response(buffer as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="${fileSlug(table.name)}-v${version.version}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
