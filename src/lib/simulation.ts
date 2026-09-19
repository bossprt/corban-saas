// Operator-facing errors of the governed simulation RPC (migration 20260926_simulation_governance_v1). Pure; no I/O.
export const SIMULATION_ERRORS = {
  customer_not_found_or_forbidden: 'Cliente não encontrado nesta organização.',
  published_table_version_not_available: 'A tabela escolhida não está publicada para esta organização.',
  term_below_table_minimum: 'Prazo abaixo do mínimo permitido pela tabela.',
  term_above_table_maximum: 'Prazo acima do máximo permitido pela tabela.',
  invalid_amount: 'Informe um valor solicitado válido.',
  invalid_term: 'Informe um prazo válido.',
  not_authorized: 'Seu perfil não pode registrar simulações.',
  rpc_unavailable: 'O registro de simulações ainda não está disponível neste ambiente (migration pendente de autorização).',
  unexpected: 'Não foi possível registrar a simulação. Nada foi salvo; tente novamente.',
} as const
export type SimulationErrorCode = keyof typeof SIMULATION_ERRORS

export function classifySimulationError(err: { message?: string; code?: string } | null | undefined): SimulationErrorCode {
  const m = String(err?.message ?? '')
  // PostgREST: function not found in the schema cache (migration not applied yet)
  if (err?.code === 'PGRST202' || /Could not find the function/i.test(m)) return 'rpc_unavailable'
  if (err?.code === '42501' || /permission denied/i.test(m)) return 'not_authorized'
  for (const code of Object.keys(SIMULATION_ERRORS) as SimulationErrorCode[]) {
    if (code !== 'unexpected' && code !== 'rpc_unavailable' && m.includes(code)) return code
  }
  return 'unexpected'
}
