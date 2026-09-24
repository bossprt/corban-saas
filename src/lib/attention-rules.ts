// Action Center rules (NEXT-WAVE-PLAN-V3, wave E). PURE and deterministic: rows in, candidate items out, with evidence. No AI, no I/O, no cost.
// A rule whose data could not be read is NOT evaluated (never treated as "zero"): the database only auto-resolves the rules that were evaluated.
import { atLeast } from './rbac'

export type Severity = 'critical' | 'high' | 'medium' | 'low'
export const SEVERITY_ORDER: readonly Severity[] = ['critical', 'high', 'medium', 'low']
export const SEVERITY_LABEL: Record<Severity, string> = { critical: 'Crítico', high: 'Alto', medium: 'Médio', low: 'Baixo' }

export type Signal = { count: number; ids: readonly string[]; oldest: string | null }  // oldest = ISO timestamp of the oldest offending row
// null = the query failed or the role may not read it: the rule is skipped.
export type AttentionData = {
  overdueCases: Signal | null      // operational cases past due_at
  staleLeads: Signal | null        // new leads waiting more than 2 days
  pendenciesDue?: Signal | null    // pendencies due within 24 hours or already late
  draftProposals: Signal | null    // proposals in draft for more than 3 days
  // Receipt reconciliation (finance_alerts; null when the caller has no finance access)
  paidWithoutReceipt?: Signal | null  // paid more than 30 days ago and no upfront received
  divergenceOpen?: Signal | null      // received amount different from the frozen commission, not accepted
  deferredMissing?: Signal | null     // deferred installments due and not received
  chargebacks?: Signal | null         // chargebacks registered in the last 30 days
}
export type Candidate = { rule_key: string; dedupe_key: string; severity: Severity; title: string; reason: string; evidence: { count: number; oldest_at: string | null; sample_ids: string[] }; impact: string; recommendation: string; href: string }

const HOUR = 3_600_000
const ageHours = (iso: string | null, now: number) => (iso && Number.isFinite(Date.parse(iso)) ? Math.max(0, (now - Date.parse(iso)) / HOUR) : 0)

type Rule = { key: keyof AttentionData; rule_key: string; allowed: (role: string | null | undefined) => boolean; build: (s: Signal, now: number) => Omit<Candidate, 'rule_key' | 'dedupe_key' | 'evidence'> }
const RULES: Rule[] = [
  { key: 'overdueCases', rule_key: 'overdue_cases', allowed: r => atLeast(r, 'supervisor'), build: (s, now) => ({
    severity: ageHours(s.oldest, now) > 72 || s.count >= 10 ? 'critical' : ageHours(s.oldest, now) > 24 || s.count >= 3 ? 'high' : 'medium',
    title: `${s.count} caso(s) da operação com o prazo vencido`, reason: 'O prazo de atendimento da etapa passou e o caso continua parado na esteira.',
    impact: 'Proposta sem andamento pode ser perdida ou vencer no banco.', recommendation: 'Abra a operação, veja o caso mais antigo e cobre o responsável ou reatribua.', href: '/app/operacao' }) },
  { key: 'staleLeads', rule_key: 'stale_leads', allowed: r => atLeast(r, 'supervisor'), build: (s, now) => ({
    severity: s.count >= 20 || ageHours(s.oldest, now) > 24 * 7 ? 'high' : 'medium',
    title: `${s.count} lead(s) novo(s) sem primeiro contato há mais de 2 dias`, reason: 'O lead entrou e ninguém registrou contato.',
    impact: 'Lead esfria: a chance de conversão cai a cada dia sem retorno.', recommendation: 'Distribua os leads mais antigos e cobre o primeiro contato.', href: '/app/leads' }) },
  { key: 'pendenciesDue', rule_key: 'pendencies_due', allowed: r => atLeast(r, 'supervisor'), build: (s, now) => ({
    severity: s.oldest && new Date(s.oldest).getTime() < now ? 'high' : 'medium',
    title: `${s.count} pendência(s) vencendo ou vencida(s)`, reason: 'O prazo para resolver a pendência pedida pelo banco termina em menos de 24 horas ou já passou.',
    impact: 'Pendência vencida pode fazer o banco cancelar a proposta.', recommendation: 'Abra a esteira na etapa Pendência e resolva as mais antigas.', href: '/app/propostas' }) },
  { key: 'paidWithoutReceipt', rule_key: 'paid_without_receipt', allowed: r => atLeast(r, 'supervisor'), build: s => ({
    severity: s.count >= 5 ? 'critical' : 'high',
    title: `${s.count} contrato(s) pago(s) sem recebimento da comissão há mais de 30 dias`, reason: 'O banco pagou o cliente, mas a comissão ainda não apareceu em nenhum relatório confirmado.',
    impact: 'Comissão que não chega é receita perdida e trava o repasse da equipe.', recommendation: 'Cobre o banco ou a promotora e importe o relatório de pagos.', href: '/app/financeiro' }) },
  { key: 'divergenceOpen', rule_key: 'receipt_divergence_open', allowed: r => atLeast(r, 'supervisor'), build: s => ({
    severity: 'high',
    title: `${s.count} recebimento(s) com valor diferente do esperado`, reason: 'O valor pago pelo banco não bate, ao centavo, com a comissão calculada na proposta.',
    impact: 'Diferença sem explicação distorce o repasse e o resultado da empresa.', recommendation: 'Abra a conciliação, confira e aceite com o motivo ou cobre a diferença.', href: '/app/financeiro/conciliacao' }) },
  { key: 'deferredMissing', rule_key: 'deferred_missing', allowed: r => atLeast(r, 'supervisor'), build: s => ({
    severity: s.count >= 10 ? 'high' : 'medium',
    title: `${s.count} contrato(s) com parcela do diferido faltando`, reason: 'Já passou o mês da parcela e ela não veio em nenhum relatório de diferido.',
    impact: 'Parcelas esquecidas somam dinheiro relevante ao longo do contrato.', recommendation: 'Confira o relatório de diferido do banco e importe o que faltar.', href: '/app/financeiro' }) },
  { key: 'chargebacks', rule_key: 'chargebacks', allowed: r => atLeast(r, 'supervisor'), build: s => ({
    severity: 'medium',
    title: `${s.count} estorno(s) registrado(s) nos últimos 30 dias`, reason: 'O banco devolveu comissão de contrato cancelado, quitado ou portado.',
    impact: 'O estorno será descontado de quem recebeu por esses contratos.', recommendation: 'Veja os contratos estornados no financeiro.', href: '/app/financeiro' }) },
  { key: 'draftProposals', rule_key: 'draft_proposals', allowed: r => atLeast(r, 'supervisor'), build: s => ({
    severity: s.count >= 10 ? 'medium' : 'low',
    title: `${s.count} proposta(s) em rascunho há mais de 3 dias`, reason: 'A proposta foi criada mas não foi enviada para a operação.',
    impact: 'Produção parada antes mesmo de chegar ao banco.', recommendation: 'Revise os rascunhos e envie ou cancele.', href: '/app/propostas' }) },
]
export const ALL_RULE_KEYS = RULES.map(r => r.rule_key)

// Candidates for the rules that were EVALUATED (data available and role allowed). `evaluated` lists them even when the result is empty, which is what lets a cleared
// condition be resolved automatically. A rule whose data is null is left out of `evaluated`.
export function evaluateRules(role: string | null | undefined, data: AttentionData, now: number = Date.now()): { candidates: Candidate[]; evaluated: string[] } {
  const candidates: Candidate[] = [], evaluated: string[] = []
  for (const r of RULES) {
    const s = data[r.key] ?? null
    if (!r.allowed(role) || s === null || !Number.isInteger(s.count) || s.count < 0) continue
    evaluated.push(r.rule_key)
    if (s.count === 0) continue
    candidates.push({ rule_key: r.rule_key, dedupe_key: r.rule_key, ...r.build(s, now), evidence: { count: s.count, oldest_at: s.oldest, sample_ids: s.ids.slice(0, 5).map(String) } })
  }
  return { candidates: candidates.sort((a, b) => SEVERITY_ORDER.indexOf(a.severity) - SEVERITY_ORDER.indexOf(b.severity)), evaluated }
}
export const isSeverity = (v: unknown): v is Severity => typeof v === 'string' && (SEVERITY_ORDER as readonly string[]).includes(v)
