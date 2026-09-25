export const ENTRY_KIND_LABEL: Record<string, string> = {
  commission: 'Comissão', chargeback: 'Estorno', advance: 'Vale', bonus: 'Bônus', discount: 'Desconto', adjustment: 'Ajuste', payout: 'Pagamento',
}
export const ENTRY_STATUS_LABEL: Record<string, string> = { approved: 'Aprovado', pending: 'Aguarda aprovação', rejected: 'Recusado' }
export const PAYOUT_STATUS_LABEL: Record<string, string> = { pending: 'Aguarda aprovação', approved: 'Aprovado, a pagar', paid: 'Pago', settled: 'Sem valor a pagar', cancelled: 'Cancelado' }
export const PAYOUT_STATUS_TONE: Record<string, 'pending' | 'diverged' | 'received' | 'neutral'> = { pending: 'pending', approved: 'diverged', paid: 'received', settled: 'neutral', cancelled: 'neutral' }
export const MODEL_LABEL: Record<string, string> = { closing: 'Fechamento periódico', account: 'Conta interna (saque)' }
export const FREQUENCY_LABEL: Record<string, string> = { weekly: 'Semanal', biweekly: 'Quinzenal', monthly: 'Mensal' }
export const dateBr = (d: string | null | undefined) => (d ? `${d.slice(8, 10)}/${d.slice(5, 7)}/${d.slice(0, 4)}` : '—')
