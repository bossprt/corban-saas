import type { NextRequest } from 'next/server'
import ExcelJS from 'exceljs'
import { requireAppContext } from '@/lib/appContext'
import { atLeast, canViewCommission } from '@/lib/rbac'
import { fetchAll } from '@/lib/fetchAll'
import { baseLabel, fileSlug, SHEET_LINE_COLUMNS, SHEET_TAIL_COLUMNS, sheetValue, valueColumns } from '@/lib/commission/tableSheet'
import { decimalBr } from '@/lib/commission/tableValues'
import { readTableFilters, searchTables } from '@/lib/commission/tableSearch'

export const dynamic = 'force-dynamic'

type Line = { id: string; product_table_version_id: string; contract_type_id: string; term: number; term_min: number | null; term_max: number | null; amount_min: string | null; coefficient: string | null; rate: string | null; tax_pct: string }
type Comp = { condition_id: string; component_type_id: string; value_kind: string; received_value: string; calculation_base: string | null }
type GroupValue = { condition_id: string; group_id: string; component_type_id: string; value_kind: string; value: string }
const CHUNK = 60

// "Exportar planilha" of the tables search (owner decision 26/09/2026): the current vigência of every table the
// filters show (one bank, or all), in the import layout, so the owner changes tax or values in Excel and imports it
// back (a new draft vigência per table). "Promotora parceira" keeps each table on its own origin when imported again;
// coefficient goes in "Coeficiente" (not "Fator"), so importing never creates daily factors. Tables that cannot go
// through the import unchanged (no published vigência, amount ranges) are listed on a second sheet.
export async function GET(req: NextRequest) {
  const { supabase, membership, organization } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor') || !canViewCommission(membership.role)) return new Response('Sem permissão', { status: 403 })
  const f = readTableFilters(k => req.nextUrl.searchParams.get(k) ?? '')
  const { rows, banks, agreements, providers, types } = await searchTables(supabase, f)

  const [{ data: components }, { data: groups }, { data: rules }] = await Promise.all([
    supabase.from('commission_component_types').select('id,tech_key,name,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active', true).order('sort_order').order('name'),
    supabase.from('commission_group_rules').select('group_id,version,own_production').order('version', { ascending: false }),
  ])
  const own = new Map<string, boolean>()
  for (const r of rules ?? []) if (!own.has(r.group_id)) own.set(r.group_id, r.own_production)
  const payGroups = (groups ?? []).filter(g => !own.get(g.id))
  const types2 = components ?? []

  const withVersion = rows.filter(x => x.current)
  const versionIds = withVersion.map(x => x.current!.id)
  const lines: Line[] = [], comp: Comp[] = [], gv: GroupValue[] = []
  for (let i = 0; i < versionIds.length; i += CHUNK) {
    const ids = versionIds.slice(i, i + CHUNK)
    const [l, c, g] = await Promise.all([
      fetchAll<Line>((a, b) => supabase.from('commercial_conditions').select('id,product_table_version_id,contract_type_id,term,term_min,term_max,amount_min,coefficient,rate,tax_pct')
        .in('product_table_version_id', ids).order('term_min').order('term').order('id').range(a, b)),
      fetchAll<Comp>((a, b) => supabase.from('commercial_condition_components')
        .select('condition_id,component_type_id,value_kind,received_value,calculation_base,commercial_conditions!inner(product_table_version_id)').in('commercial_conditions.product_table_version_id', ids).order('id').range(a, b)),
      fetchAll<GroupValue>((a, b) => supabase.from('commercial_condition_group_values')
        .select('condition_id,group_id,component_type_id,value_kind,value,commercial_conditions!inner(product_table_version_id)').in('commercial_conditions.product_table_version_id', ids)
        .order('condition_id').order('group_id').order('component_type_id').range(a, b)),
    ])
    lines.push(...l); comp.push(...c); gv.push(...g)
  }

  const linesOf = new Map<string, Line[]>()
  for (const l of lines) linesOf.set(l.product_table_version_id, [...(linesOf.get(l.product_table_version_id) ?? []), l])
  const companyOf = new Map(comp.map(c => [`${c.condition_id}:${c.component_type_id}`, c]))
  const groupOf = new Map(gv.map(g => [`${g.condition_id}:${g.group_id}:${g.component_type_id}`, g]))
  const baseOf = new Map<string, string>()
  for (const c of comp) if (c.calculation_base && !baseOf.has(c.condition_id)) baseOf.set(c.condition_id, c.calculation_base)
  const name = (list: { id: string; name: string }[]) => new Map(list.map(r => [r.id, r.name]))
  const bankN = name(banks), agrN = name(agreements), provN = name(providers), typeN = name(types)

  const wb = new ExcelJS.Workbook()
  const ws = wb.addWorksheet('Tabelas')
  const columns = [...SHEET_LINE_COLUMNS, 'Promotora parceira', 'Coeficiente', 'Taxa a.m. (%)', ...SHEET_TAIL_COLUMNS, ...valueColumns(types2, payGroups)]
  ws.addRow(columns)
  const skipped: [string, string, string][] = rows.filter(x => !x.current).map(x => [bankN.get(x.r.org_bank_id) ?? '', x.t.name, 'Sem vigência publicada'])
  let exported = 0
  for (const x of withVersion) {
    const v = x.current!
    const tLines = linesOf.get(v.id) ?? []
    if (tLines.some(l => l.amount_min !== null)) { skipped.push([bankN.get(x.r.org_bank_id) ?? '', x.t.name, 'Tem faixas de valor da operação (a importação ainda não lê faixas)']); continue }
    const code = String((v.metadata as { external_table_code?: string } | null)?.external_table_code ?? (x.t.code?.startsWith('t-') ? '' : x.t.code ?? ''))
    for (const l of tLines) {
      ws.addRow([
        bankN.get(x.r.org_bank_id) ?? '', agrN.get(x.r.org_agreement_id) ?? '', x.t.name, code,
        // Vigência left empty: imported back, the new vigência starts when it is published (never retroactive).
        '', '', typeN.get(l.contract_type_id) ?? '',
        l.term_min ?? l.term, l.term_max ?? l.term,
        x.r.org_provider_id ? provN.get(x.r.org_provider_id) ?? '' : '',
        l.coefficient === null ? '' : decimalBr(l.coefficient), l.rate === null ? '' : decimalBr(l.rate),
        baseLabel(baseOf.get(l.id)), Number(l.tax_pct) ? decimalBr(l.tax_pct) : '0',
        ...types2.map(t => { const c = companyOf.get(`${l.id}:${t.id}`); return sheetValue(c?.value_kind, c?.received_value) }),
        ...payGroups.flatMap(g => types2.map(t => { const gvx = groupOf.get(`${l.id}:${g.id}:${t.id}`); return sheetValue(gvx?.value_kind, gvx?.value) })),
      ])
    }
    exported++
  }
  ws.views = [{ state: 'frozen', ySplit: 1 }]
  ws.getRow(1).font = { bold: true }
  ws.columns = columns.map((h, i) => ({ key: String(i), width: Math.min(42, Math.max(12, h.length + 2)) }))

  const guide = wb.addWorksheet('Como usar')
  guide.addRows([
    ['Como usar esta planilha'],
    ['1', 'Altere o que precisar (Imposto (%), valores da Empresa ou dos grupos). Número = % da operação; "R$ 25,00" = valor fixo.'],
    ['2', 'Importe em Cadastros > Tabelas > Importar planilha. Cada tabela ganha uma nova vigência em rascunho; as publicadas não mudam.'],
    ['3', 'Confira e publique. Vigência Inicial vazia = a nova vigência começa quando você publicar (preencha só se quiser outra data).'],
    ['Promotora parceira', 'Vazio = produção própria. Mantenha o nome como está: é assim que cada tabela volta para a sua origem.'],
  ])
  guide.getRow(1).font = { bold: true }
  guide.getColumn(1).width = 20; guide.getColumn(2).width = 110

  const info = wb.addWorksheet('Fora da exportação')
  info.addRow(['Banco', 'Tabela', 'Motivo'])
  info.getRow(1).font = { bold: true }
  for (const s of skipped) info.addRow(s)
  if (!skipped.length) info.addRow(['', 'Nenhuma: todas as tabelas da pesquisa estão na aba Tabelas.', ''])
  info.getColumn(1).width = 24; info.getColumn(2).width = 60; info.getColumn(3).width = 60

  const bank = f.banco ? bankN.get(f.banco) : ''
  const buffer = await wb.xlsx.writeBuffer()
  return new Response(buffer as ArrayBuffer, {
    headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="tabelas-${fileSlug(bank || organization.name)}-${exported}.xlsx"`,
      'Cache-Control': 'no-store',
    },
  })
}
