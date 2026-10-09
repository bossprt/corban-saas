import type { Tone } from '@/components/ui'

// Labels of the improvement requests (owner, 08/10/2026), shared by the company page and the platform.
export const IMPROVEMENT_KIND: Record<string, string> = { improvement: 'Melhoria', bug: 'Erro (algo não funciona)', question: 'Dúvida' }
export const IMPROVEMENT_STATUS: Record<string, [string, Tone]> = {
  received: ['Recebida', 'neutral'], analyzing: ['Em análise', 'pending'], approved: ['Aprovada: vai ser feita', 'expected'],
  declined: ['Não será feita', 'reversed'], delivered: ['Entregue', 'received'],
}
