// Company finance (F6.5): words the screens use. No I/O.
export const FIN_KIND_LABEL: Record<string, string> = {
  income: 'Receita', deduction: 'Dedução da receita', cost: 'Custo', expense: 'Despesa',
  financial_income: 'Receita financeira', financial_expense: 'Despesa financeira', transfer: 'Transferência',
}
export const FIN_STATUS_LABEL: Record<string, string> = { open: 'Em aberto', settled: 'Baixado', cancelled: 'Cancelado' }
export const FIN_SOURCE_LABEL: Record<string, string> = { manual: 'Manual', commission_receipt: 'Comissão do banco', payout: 'Repasse', statement: 'Extrato' }
export const FIN_BANKS = ['C6 Bank', 'Banco do Brasil', 'Inter', 'PagSeguro', 'Outro'] as const

// Income statement lines, in order: each kind with the sign it carries and the subtotal after it.
export const DRE_ORDER: { kind: string; label: string; subtotal?: string }[] = [
  { kind: 'income', label: 'Receita bruta' },
  { kind: 'deduction', label: '(-) Deduções', subtotal: 'Receita líquida' },
  { kind: 'cost', label: '(-) Custos (repasse)', subtotal: 'Margem de contribuição' },
  { kind: 'expense', label: '(-) Despesas', subtotal: 'Resultado operacional' },
  { kind: 'financial_income', label: '(+) Receitas financeiras' },
  { kind: 'financial_expense', label: '(-) Despesas financeiras', subtotal: 'Resultado do período' },
]

export const brl = (v: number | string | null | undefined) =>
  v === null || v === undefined || v === '' ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
export const monthLabel = (iso: string) => new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('pt-BR', { month: 'short', year: '2-digit' })
export const dayLabel = (iso: string | null) => (iso ? new Date(`${iso.slice(0, 10)}T12:00:00Z`).toLocaleDateString('pt-BR') : '—')
