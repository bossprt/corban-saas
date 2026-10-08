'use server'

import { revalidatePath } from 'next/cache'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { xlsxSheets } from '@/lib/commercial-xlsx'
import { parseFactorPrice, type FactorPriceSheet } from '@/lib/imports/factor-price'

// The bank's Fator Price files (08/10/2026): check on the screen first, then import. Both steps read the same files
// again, so what is imported is exactly what was shown.
export type FactorPricePreview = {
  ok: boolean
  message?: string
  issues: { sheet: string; message: string }[]
  tables: { code: string; label: string; dates: number; first: string; last: string; terms: number[]; today: string | null; systemTables: { name: string; provider: string }[] }[]
  withoutFactor: { code: string | null; name: string; provider: string }[]
}
export type FactorPriceResult = { ok: boolean; message: string }

const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v)
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())

async function read(f: FormData) {
  const ctx = await requireAppContext()
  if (!atLeast(ctx.membership.role, 'manager')) return { error: 'Sem permissão.' } as const
  const bank = String(f.get('bank') ?? ''), agreement = String(f.get('agreement') ?? '')
  if (!uuid(bank) || !uuid(agreement)) return { error: 'Escolha o banco e o convênio.' } as const
  const files = f.getAll('files').filter((x): x is File => x instanceof File && x.size > 0)
  if (!files.length || files.length > 10) return { error: 'Escolha de 1 a 10 planilhas Fator Price (.xlsx).' } as const
  const all: { name: string; rows: string[][] }[] = []
  for (const file of files) {
    if (file.size > 3_000_000 || !/\.xlsx$/i.test(file.name)) return { error: `${file.name}: só .xlsx até 3 MB.` } as const
    try {
      for (const s of await xlsxSheets(Buffer.from(await file.arrayBuffer()))) all.push({ name: `${file.name} / ${s.name}`, rows: s.rows })
    } catch { return { error: `${file.name}: não consegui ler a planilha.` } as const }
  }
  const parsed = parseFactorPrice(all)
  return { ctx, bank, agreement, files, parsed } as const
}

export async function previewFactorPrice(f: FormData): Promise<FactorPricePreview> {
  const r = await read(f)
  if ('error' in r) return { ok: false, message: String(r.error), issues: [], tables: [], withoutFactor: [] }
  const { ctx, bank, agreement, parsed } = r
  const { data } = await ctx.supabase.from('product_tables')
    .select('name,bank_table_code,status,organization_product_routes!inner(org_bank_id,org_agreement_id,organization_providers(name))')
    .eq('organization_product_routes.org_bank_id', bank).eq('organization_product_routes.org_agreement_id', agreement).eq('status', 'active').order('name')
  type Row = { name: string; bank_table_code: string | null; organization_product_routes: { organization_providers: { name: string } | null } | { organization_providers: { name: string } | null }[] }
  const rows = ((data ?? []) as unknown as Row[]).map(x => {
    const route = Array.isArray(x.organization_product_routes) ? x.organization_product_routes[0] : x.organization_product_routes
    return { code: x.bank_table_code, name: x.name, provider: route?.organization_providers?.name ?? 'Produção própria' }
  })
  const t = today()
  const tables = parsed.sheets.map((s: FactorPriceSheet) => {
    const dates = s.dates.map(d => d.date).sort()
    const now = s.dates.find(d => d.date === t)
    return {
      code: s.code, label: s.label, dates: dates.length, first: dates[0], last: dates[dates.length - 1],
      terms: [...new Set(s.dates.flatMap(d => d.entries.map(e => e.term)))].sort((a, b) => a - b),
      today: now ? now.entries.map(e => `${e.term}x ${e.factor.replace('.', ',')}`).join(' · ') : null,
      systemTables: rows.filter(x => x.code === s.code).map(x => ({ name: x.name, provider: x.provider })),
    }
  })
  const codes = new Set(parsed.sheets.map(s => s.code))
  return { ok: tables.length > 0, message: tables.length ? undefined : 'Nenhuma tabela com fator nas planilhas.', issues: parsed.issues, tables, withoutFactor: rows.filter(x => !x.code || !codes.has(x.code)) }
}

export async function importFactorPrice(f: FormData): Promise<FactorPriceResult> {
  const r = await read(f)
  if ('error' in r) return { ok: false, message: String(r.error) }
  const { ctx, bank, agreement, files, parsed } = r
  if (parsed.issues.length) return { ok: false, message: 'Corrija os avisos da conferência antes de importar.' }
  if (!parsed.sheets.length) return { ok: false, message: 'Nenhuma tabela com fator nas planilhas.' }
  const { data, error } = await ctx.supabase.rpc('import_factor_price', {
    p_org: ctx.membership.organization_id, p_bank: bank, p_agreement: agreement,
    p_sheets: parsed.sheets.map(s => ({ code: s.code, label: s.label, dates: s.dates })),
    p_source_note: `Fator Price: ${files.map(x => x.name).join(', ')}`.slice(0, 200),
  })
  if (error) return { ok: false, message: error.message.includes('not_authorized') ? 'Sem permissão.' : 'Não foi possível importar. Nada foi gravado.' }
  revalidatePath('/app/comercial/fatores')
  const d = data as { profiles_created: number; batches_published: number; batches_unchanged: number; codes_without_table: string[] }
  return { ok: true, message: `Importado: ${d.profiles_created} perfis novos, ${d.batches_published} dias publicados, ${d.batches_unchanged} dias iguais ao que já estava.${d.codes_without_table.length ? ` Sem tabela no sistema (não importadas): ${d.codes_without_table.join(', ')}.` : ''}` }
}
