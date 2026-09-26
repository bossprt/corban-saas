import { decimalBr } from './tableValues'

// Column layout shared by the import template and the table export, so an exported table imports back as it is
// (ADR-0037): line data, base and tax, then the company block and one block per paid seller group.
// Every header is one the smart import reads (src/lib/imports/smart-commercial.ts).
export const SHEET_LINE_COLUMNS = [
  'Banco', 'Convênio', 'Tabela', 'Código no Banco',
  'Vigência Inicial', 'Vigência Final', 'Tipo de Contrato', 'Prazo Inicial', 'Prazo Final',
] as const
export const SHEET_TAIL_COLUMNS = ['Base de Cálculo', 'Imposto (%)'] as const

export function valueColumns(components: readonly { name: string }[], groups: readonly { name: string }[]): string[] {
  return [
    ...components.map(c => `${c.name} (Empresa)`),
    ...groups.flatMap(g => components.map(c => `${c.name} (${g.name})`)),
  ]
}

// A value as the person types it: "2,5" (% of the operation) or "R$ 25,00" (fixed). Empty when there is none.
export const sheetValue = (kind: string | undefined, v: string | null | undefined) =>
  v === undefined || v === null || v === '' ? '' : kind === 'fixed_brl' ? `R$ ${decimalBr(v, true)}` : decimalBr(v)

// Calendar day stored at 00:00 UTC -> "01/09/2026".
export const sheetDate = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'UTC' }) : '')

export const baseLabel = (b: string | null | undefined) => (!b ? '' : /^l/i.test(b) ? 'Líquido' : 'Bruto')

export const fileSlug = (s: string) =>
  s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase() || 'tabela'
