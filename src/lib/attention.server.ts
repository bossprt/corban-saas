import type { requireAppContext } from '@/lib/appContext'
import { evaluateRules, type AttentionData, type Candidate, type Signal } from '@/lib/attention-rules'

type Ctx = Awaited<ReturnType<typeof requireAppContext>>

export type AttentionRow = { id: string; rule_key: string; severity: string; title: string; reason: string; evidence: { count?: number; oldest_at?: string | null } | null; impact: string; recommendation: string; href: string; status: string; snoozed_until: string | null; first_detected_at: string; assigned_to: string | null }
export type AttentionEvent = { item_id: string; event: string; note: string | null; created_at: string }

export const ATTENTION_RULE_KEYS = ['overdue_cases', 'stale_leads', 'draft_proposals', 'pendencies_due'] as const

const isoAgo = (ms: number) => new Date(Date.now() - ms).toISOString()

// A failed query is "not evaluated" (null), never zero.
function signal(res: { data: { id: string; [k: string]: unknown }[] | null; count: number | null; error: unknown }, dateCol?: string): Signal | null {
  if (res.error || res.count === null) return null
  const rows = res.data ?? []
  const first = dateCol && rows[0] ? String(rows[0][dateCol] ?? '') : null
  return { count: res.count, ids: rows.slice(0, 5).map(r => r.id), oldest: first || null }
}

function liveRow(c: Candidate): AttentionRow {
  return { id: c.dedupe_key, rule_key: c.rule_key, severity: c.severity, title: c.title, reason: c.reason, evidence: { count: c.evidence.count, oldest_at: c.evidence.oldest_at }, impact: c.impact, recommendation: c.recommendation, href: c.href, status: 'open', snoozed_until: null, first_detected_at: '', assigned_to: null }
}

// Evaluates the objective attention rules for the caller's role, persists the lifecycle through sync_attention_items
// and returns the items to show. Used by the Hoje screen and the Central de atenção.
export async function loadAttention({ supabase, membership }: Ctx, opts: { withEvents?: boolean } = {}) {
  const exact = { count: 'exact' } as const
  const [overdue, stale, drafts, pendencies] = await Promise.all([
    supabase.from('operational_cases').select('id,due_at', exact).not('canonical_state', 'in', '("paid","cancelled","rejected")').lt('due_at', isoAgo(0)).order('due_at').limit(200),
    supabase.from('leads').select('id,created_at', exact).eq('status', 'new').lt('created_at', isoAgo(2 * 24 * 3600 * 1000)).order('created_at').limit(200),
    supabase.from('proposals_v2').select('id,created_at', exact).eq('status', 'draft').lt('created_at', isoAgo(3 * 24 * 3600 * 1000)).order('created_at').limit(200),
    supabase.from('operational_cases').select('id,pendency_due_at', exact).eq('canonical_state', 'pending_external').lt('pendency_due_at', isoAgo(-24 * 3600 * 1000)).order('pendency_due_at').limit(200),
  ])
  const data: AttentionData = { overdueCases: signal(overdue, 'due_at'), staleLeads: signal(stale, 'created_at'), draftProposals: signal(drafts, 'created_at'), pendenciesDue: signal(pendencies, 'pendency_due_at') }
  const { candidates, evaluated } = evaluateRules(membership.role, data)

  // Persist the lifecycle (history, decisions). Without the Action Center migration the live signals are still shown, without history.
  const sync = await supabase.rpc('sync_attention_items', { p_organization: membership.organization_id, p_rule_keys: evaluated, p_items: candidates })
  const persistent = !sync.error
  let items: AttentionRow[] = []
  let events: AttentionEvent[] = []
  if (persistent) {
    const res = await supabase.from('operational_attention_items').select('id,rule_key,severity,title,reason,evidence,impact,recommendation,href,status,snoozed_until,first_detected_at,assigned_to').in('status', ['open', 'snoozed', 'dismissed']).order('last_detected_at', { ascending: false }).limit(100)
    items = (res.data ?? []) as AttentionRow[]
    if (opts.withEvents && items.length) events = ((await supabase.from('operational_attention_events').select('item_id,event,note,created_at').in('item_id', items.map(i => i.id)).order('created_at', { ascending: false }).limit(300)).data ?? []) as AttentionEvent[]
  }
  return {
    persistent,
    items: persistent ? items : candidates.map(liveRow),
    events,
    notEvaluated: ATTENTION_RULE_KEYS.filter(k => !evaluated.includes(k)),
  }
}
