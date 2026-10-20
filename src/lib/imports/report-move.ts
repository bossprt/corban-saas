// A contract already in Corban follows the bank's report (owner, 20/10/2026): it only moves forward; "Em análise" and
// "Pendência" may swap; Paga, Cancelada and Recusada never change; Cancelada in the file cancels a contract not paid yet.
// Values, seller and commission never change from a file.
const STAGE_RANK: Record<string, number> = { digitization_queue: 0, digitizing: 1, submitted: 2, pending_external: 2, approved: 3, paid: 4 }
const FINAL = new Set(['paid', 'cancelled', 'rejected'])
export function reportMove(current: string, target: string): 'move' | 'same' | 'never' | 'paid_conflict' {
  if (current === target) return 'same'
  if (FINAL.has(current)) return current === 'paid' && (target === 'cancelled' || target === 'rejected') ? 'paid_conflict' : 'never'
  if (target === 'cancelled' || target === 'rejected') return 'move'
  const a = STAGE_RANK[current], b = STAGE_RANK[target]
  if (a === undefined || b === undefined) return 'never'
  return b > a || (b === a && b === 2) ? 'move' : 'never'
}
