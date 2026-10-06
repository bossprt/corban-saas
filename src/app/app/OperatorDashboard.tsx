import Link from 'next/link'
import { AlertTriangle, ChevronRight } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { add, cmp, div, fromDecimalString, isZero, mul, toDecimalString, type Rational } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'
import { memberEmails } from '@/lib/team.server'

type Supa = Awaited<ReturnType<typeof import('@/lib/appContext').requireAppContext>>['supabase']
type Stage = { id: string; code: string; name: string; canonical_state: string; sort_order: number }
type Case = { id: string; proposal_id: string; current_stage_id: string | null; canonical_state: string; entered_stage_at: string; due_at: string | null; pendency_reason: string | null; pendency_due_at: string | null }
type Proposal = { id: string; external_proposal_id: string | null; customer_snapshot: { full_name?: string } | null; product_table_version_id: string | null }
type Goal = { user_id: string; target_amount: string | number | null; paid_amount: string | number | null; paid_count: number | null }

const OPEN = '("paid","cancelled","rejected")'
const STUCK_DAYS = 3
const R = (v: string | number | null | undefined) => fromDecimalString(String(v ?? 0))
const money = (v: Rational) => brlText(toDecimalString(v, 2))
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date())
const nowMs = () => Date.now()
const daysSince = (iso: string) => Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000))
const ago = (iso: string) => { const d = daysSince(iso); return d === 0 ? 'hoje' : d === 1 ? 'há 1 dia' : `há ${d} dias` }
const dateBr = (iso: string) => new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })

// The operator's dashboard (06/10/2026, model C): what to do today. Contracts stopped in a stage, bank pendencies with
// their deadline, the pipeline by stage, contracts paid this month and the month's goals. No commission or company
// money here; every row opens the contract. What each person sees follows their scope (RLS), as everywhere.
export async function OperatorDashboard({ supabase, organizationId, organizationName, onlyUserId }: { supabase: Supa; organizationId: string; organizationName?: string; onlyUserId?: string }) {
  const day = today()
  const month = `${day.slice(0, 8)}01`
  const [{ data: stageRows }, { data: caseRows }, { data: paidRows }, { data: goalRows }, { data: docRows }] = await Promise.all([
    supabase.from('operational_stages').select('id,code,name,canonical_state,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('operational_cases').select('id,proposal_id,current_stage_id,canonical_state,entered_stage_at,due_at,pendency_reason,pendency_due_at')
      .not('canonical_state', 'in', OPEN).order('entered_stage_at').limit(500),
    supabase.from('proposals_v2').select('id,released_amount,requested_amount').eq('status', 'paid').gte('paid_to_client_on', month).lte('paid_to_client_on', day).limit(2000),
    supabase.rpc('goal_progress', { p_org: organizationId, p_month: month }),
    supabase.from('proposal_document_requirements').select('proposal_id').eq('required_snapshot', true).not('status', 'in', '("validated","waived")').limit(2000),
  ])
  const stages = (stageRows ?? []) as Stage[]
  const cases = (caseRows ?? []) as Case[]
  const stageOf = new Map(stages.map(s => [s.id, s]))
  const ids = [...new Set(cases.map(c => c.proposal_id))]
  const { data: proposalRows } = ids.length
    ? await supabase.from('proposals_v2').select('id,external_proposal_id,customer_snapshot,product_table_version_id').in('id', ids.slice(0, 500))
    : { data: [] }
  const proposalOf = new Map(((proposalRows ?? []) as Proposal[]).map(p => [p.id, p]))
  const openIds = new Set(ids)

  const now = nowMs()
  const stuck = cases.filter(c => daysSince(c.entered_stage_at) >= STUCK_DAYS)
  const pendencies = cases.filter(c => c.canonical_state === 'pending_external')
  const pendencyLate = pendencies.filter(c => c.pendency_due_at && new Date(c.pendency_due_at).getTime() < now)
  const docsMissing = new Set(((docRows ?? []) as { proposal_id: string }[]).map(d => d.proposal_id).filter(id => openIds.has(id)))
  const paidTotal = ((paidRows ?? []) as { released_amount: string | null; requested_amount: string | null }[]).reduce((a, p) => add(a, R(p.released_amount ?? p.requested_amount)), R(0))
  const paidCount = (paidRows ?? []).length

  // What needs someone now: late pendencies first, then the contracts stopped the longest.
  const urgent = [
    ...pendencyLate.map(c => ({ c, why: `Pendência vencida em ${dateBr(c.pendency_due_at!)}${c.pendency_reason ? ` · ${c.pendency_reason}` : ''}`, tone: 'danger' as const })),
    ...stuck.filter(c => !pendencyLate.includes(c)).map(c => ({ c, why: `Parado ${ago(c.entered_stage_at)} em ${stageOf.get(c.current_stage_id ?? '')?.name ?? 'etapa'}${c.pendency_reason ? ` · ${c.pendency_reason}` : ''}`, tone: 'warn' as const })),
  ].slice(0, 12)

  const byStage = new Map<string, number>()
  for (const c of cases) if (c.current_stage_id) byStage.set(c.current_stage_id, (byStage.get(c.current_stage_id) ?? 0) + 1)
  const pipeline = stages.filter(s => byStage.has(s.id))

  // An agent sees only their own goal; contracts are already scoped by RLS (own, team or company).
  const goals = ((goalRows ?? []) as Goal[]).filter(g => (!onlyUserId || g.user_id === onlyUserId) && (!isZero(R(g.target_amount)) || !isZero(R(g.paid_amount))))
  const goalUsers = goals.map(g => g.user_id)
  const [{ data: sellerRows }, emails] = goalUsers.length
    ? await Promise.all([supabase.from('commercial_sellers').select('user_id,name').in('user_id', goalUsers), memberEmails(goalUsers)])
    : [{ data: [] }, new Map<string, string>()]
  const nameOf = new Map(((sellerRows ?? []) as { user_id: string; name: string }[]).map(s => [s.user_id, s.name]))
  const goalLines = goals.map(g => {
    const target = R(g.target_amount), paid = R(g.paid_amount)
    const pct = isZero(target) ? null : Number(toDecimalString(mul(div(paid, target), R(100)), 0))
    return { id: g.user_id, name: nameOf.get(g.user_id) ?? emails.get(g.user_id) ?? 'Usuário', target, paid, count: g.paid_count ?? 0, pct }
  }).sort((a, b) => cmp(b.paid, a.paid))

  const kpis = [
    { label: 'Na esteira', value: String(cases.length), hint: 'contratos em andamento', href: '/app/propostas', tone: '' },
    { label: `Parados há ${STUCK_DAYS}+ dias`, value: String(stuck.length), hint: 'sem mudar de etapa', href: '/app/propostas', tone: stuck.length ? 'text-[#92400E]' : '' },
    { label: 'Pendências no banco', value: String(pendencies.length), hint: pendencyLate.length ? `${pendencyLate.length} com prazo vencido` : 'nenhuma vencida', href: '/app/propostas?etapa=' + (stages.find(s => s.canonical_state === 'pending_external')?.code ?? ''), tone: pendencyLate.length ? 'text-[#B91C1C]' : '' },
    { label: 'Pagos no mês', value: String(paidCount), hint: money(paidTotal), href: `/app/contratos?situacao=paid&pago_de=${month}&pago_ate=${day}&n=100`, tone: '' },
  ]

  return (
    <section>
      <PageHeader title="Visão geral" description={organizationName} />
      <div className="mb-4 grid grid-cols-2 gap-3 xl:grid-cols-4">
        {kpis.map(k => (
          <Link key={k.label} href={k.href} className="flex flex-col gap-1 rounded-[14px] border border-line bg-surface px-5 py-4 hover:border-line-strong hover:bg-surface-muted">
            <span className="text-[13px] font-medium text-muted">{k.label}</span>
            <span className={`num text-[26px] font-semibold tracking-tight ${k.tone || 'text-ink'}`}>{k.value}</span>
            <span className="text-xs text-ink-soft">{k.hint}</span>
          </Link>
        ))}
      </div>

      <Card className="mb-4">
        <CardHeader title={<span className="flex items-center gap-2"><AlertTriangle size={16} aria-hidden className={urgent.length ? 'text-[#B45309]' : 'text-muted'} />Precisa de você <Badge tone={urgent.length ? 'pending' : 'neutral'}>{urgent.length}</Badge></span>} />
        {urgent.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhum contrato parado ou com pendência vencida.</p> : (
          <ul className="mt-2">{urgent.map(({ c, why, tone }) => {
            const p = proposalOf.get(c.proposal_id)
            return (
              <li key={c.id}><Link href={`/app/propostas/${c.proposal_id}`} className="flex items-center justify-between gap-3 border-t border-line px-5 py-3 hover:bg-surface-muted">
                <span className="min-w-0"><span className="block truncate text-sm font-medium text-ink">{p?.customer_snapshot?.full_name ?? 'Contrato'}{p?.external_proposal_id ? <span className="font-normal text-muted"> · nº {p.external_proposal_id}</span> : null}</span>
                  <span className={`block truncate text-[13px] ${tone === 'danger' ? 'text-[#B91C1C]' : 'text-[#92400E]'}`}>{why}</span></span>
                <ChevronRight size={16} aria-hidden className="shrink-0 text-muted" />
              </Link></li>
            )
          })}</ul>
        )}
      </Card>

      <div className="mb-4 grid gap-4 xl:grid-cols-2">
        <Card>
          <CardHeader title="Esteira por etapa" />
          {pipeline.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhum contrato em andamento.</p> : (
            <ul className="px-5 pb-4 pt-2">{pipeline.map(s => {
              const n = byStage.get(s.id) ?? 0
              return (
                <li key={s.id}><Link href={`/app/propostas?etapa=${encodeURIComponent(s.code)}`} className="flex items-center gap-3 rounded-md py-1.5 hover:bg-surface-muted">
                  <span className="w-40 shrink-0 truncate text-[13px] text-ink">{s.name}</span>
                  <span className="h-2 flex-1 rounded-full bg-surface-muted"><span className={`block h-2 rounded-full ${s.canonical_state === 'pending_external' ? 'bg-[#EF9F27]' : 'bg-brand/80'}`} style={{ width: `${Math.max(4, Math.round((n / Math.max(...byStage.values())) * 100))}%` }} /></span>
                  <span className="num w-8 text-right text-sm font-semibold text-ink">{n}</span>
                </Link></li>
              )
            })}</ul>
          )}
          {docsMissing.size > 0 && <p className="border-t border-line px-5 py-3 text-[13px] text-[#92400E]">{docsMissing.size} contrato(s) em andamento com documento obrigatório faltando.</p>}
        </Card>
        <Card>
          <CardHeader title="Metas do mês" action={<Link href="/app/metas" className="text-xs text-brand hover:underline">Ver metas</Link>} />
          {goalLines.length === 0 ? <p className="px-5 pb-5 pt-2 text-sm text-muted">Nenhuma meta definida para este mês.</p> : (
            <ul className="px-5 pb-4 pt-2">{goalLines.map(g => (
              <li key={g.id} className="py-1.5">
                <span className="flex items-baseline justify-between gap-2 text-[13px]"><span className="truncate text-ink">{g.name}</span><span className="num shrink-0 text-ink-soft">{money(g.paid)}{!isZero(g.target) && <> de {money(g.target)}</>}</span></span>
                <span className="mt-1 block h-2 rounded-full bg-surface-muted"><span className={`block h-2 rounded-full ${g.pct === null ? 'bg-brand/60' : g.pct >= 90 ? 'bg-[#1D9E75]' : g.pct >= 60 ? 'bg-[#EF9F27]' : 'bg-[#E24B4A]'}`} style={{ width: `${g.pct === null ? 100 : Math.min(100, Math.max(2, g.pct))}%` }} /></span>
                <span className="mt-0.5 block text-[11px] text-muted">{g.count} contrato(s) pago(s){g.pct !== null ? ` · ${g.pct}% da meta` : ' · sem meta definida'}</span>
              </li>
            ))}</ul>
          )}
        </Card>
      </div>
      <p className="text-xs text-muted">Contratos que você pode ver no seu perfil. Toque em qualquer item para abrir.</p>
    </section>
  )
}
