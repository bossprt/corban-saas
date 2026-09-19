import { atLeast, canViewCommission } from './rbac'

// "Precisa da sua atenção": deterministic, role-aware list built from counts the page already fetched. No scoring, no AI.
// A count the caller may not see is never even requested (see the dashboard), and this function drops it again as a second lock.
export type ActionCounts = {
  staleLeads?: number | null        // new leads waiting more than 2 days
  draftProposals?: number | null    // proposals still in draft
  overdueCases?: number | null      // esteira cases past their SLA
  failedRuns?: number | null        // integration runs that failed terminally (supervisor+)
  reconciliations?: number | null   // divergent / needing a decision (commission viewers)
  importReviews?: number | null     // import matches waiting for a human (supervisor+)
}
export type ActionItem = { key: keyof ActionCounts; label: string; count: number; href: string; hint: string }

type Rule = { key: keyof ActionCounts; label: string; href: string; hint: string; allowed: (role: string | null | undefined) => boolean }
const RULES: Rule[] = [
  { key: 'overdueCases', label: 'Casos da operação com prazo vencido', href: '/app/operacao', hint: 'O prazo de atendimento da etapa passou.', allowed: () => true },
  { key: 'draftProposals', label: 'Propostas em rascunho', href: '/app/propostas', hint: 'Ainda não foram enviadas para a operação.', allowed: () => true },
  { key: 'staleLeads', label: 'Leads novos há mais de 2 dias', href: '/app/leads', hint: 'Sem primeiro contato registrado.', allowed: () => true },
  { key: 'failedRuns', label: 'Integrações com falha definitiva', href: '/app/integracoes', hint: 'Precisam de decisão: corrigir a causa e criar uma nova execução.', allowed: r => atLeast(r, 'supervisor') },
  { key: 'importReviews', label: 'Importações aguardando revisão humana', href: '/app/importacoes', hint: 'Vínculos incertos entre a planilha e as propostas.', allowed: r => atLeast(r, 'supervisor') },
  { key: 'reconciliations', label: 'Conciliações pendentes', href: '/app/financeiro', hint: 'Divergentes ou aguardando decisão.', allowed: canViewCommission },
]

export function actionItems(role: string | null | undefined, counts: ActionCounts): ActionItem[] {
  const out: ActionItem[] = []
  for (const r of RULES) {
    const n = counts[r.key]
    if (!r.allowed(role) || typeof n !== 'number' || !Number.isFinite(n) || n <= 0) continue
    out.push({ key: r.key, label: r.label, count: Math.floor(n), href: r.href, hint: r.hint })
  }
  return out
}
