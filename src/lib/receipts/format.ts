// Money display from exact decimal strings ("1234.56" -> "R$ 1.234,56"), without going through a JavaScript number.
export function brlText(v: string | number | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—'
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(v))
  if (!m) return String(v)
  const int = m[2].replace(/^0+(?=\d)/, '').replace(/\B(?=(\d{3})+(?!\d))/g, '.')
  return `${m[1]}R$ ${int},${(m[3] ?? '').padEnd(2, '0').slice(0, 2)}`
}

export const REPORT_KIND_LABEL: Record<string, string> = { upfront: 'À vista', deferred: 'Diferido', chargeback: 'Estorno' }
export const REPORT_STATUS_LABEL: Record<string, string> = { draft: 'Em conferência', confirmed: 'Confirmado', discarded: 'Descartado' }
export const LINE_STATUS_LABEL: Record<string, string> = {
  ok: 'Confere', divergent: 'Diverge', not_found: 'Não encontrado', ambiguous: 'Mais de uma proposta', duplicate: 'Já recebido',
  no_calc: 'Sem comissão calculada', installment_invalid: 'Parcela inválida', ignored: 'Ignorada',
}
export const LINE_STATUS_TONE: Record<string, 'received' | 'diverged' | 'reversed' | 'neutral' | 'pending'> = {
  ok: 'received', divergent: 'diverged', not_found: 'reversed', ambiguous: 'reversed', duplicate: 'reversed', no_calc: 'pending', installment_invalid: 'reversed', ignored: 'neutral',
}
export const ALERT_LABEL: Record<string, string> = {
  paid_without_receipt: 'Paga sem recebimento há mais de 30 dias', divergence_open: 'Recebimento divergente em aberto',
  deferred_missing: 'Parcela do diferido faltando', chargeback: 'Estorno registrado (30 dias)',
}
