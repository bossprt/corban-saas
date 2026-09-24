import Link from 'next/link'
import { FilePlus2 } from 'lucide-react'
import { Badge, ButtonLink, Card, PageHeader, type Tone } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { formatCpf } from '@/lib/cpf'

type CaseRow = { id: string; proposal_id: string; current_stage_id: string; canonical_state: string; entered_stage_at: string; due_at: string | null; pendency_due_at: string | null; pendency_reason: string | null }
type ProposalRow = { id: string; external_proposal_id: string | null; requested_amount: number | null; released_amount: number | null; customer_snapshot: Record<string, unknown> | null; commercial_snapshot: Record<string, unknown> | null; seller_id: string | null; created_by: string | null }

const CLOSED = ['paid', 'rejected', 'cancelled']
const STATE_TONE: Record<string, Tone> = {
  digitization_queue: 'neutral', digitizing: 'expected', submitted: 'paid-out', pending_external: 'diverged',
  approved: 'received', paid: 'received', rejected: 'reversed', cancelled: 'neutral',
}
const brl = (v: number | null) => (v === null || v === undefined ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }))
// Server-rendered per request.
const requestTime = () => Date.now()
const days = (iso: string) => Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000))

// Esteira: every proposal in the pipeline with its stage, how long it is there and the alerts that need action.
// Stages are the company's own (names and order); visibility follows the caller's scope (RLS).
export default async function PipelinePage({ searchParams }: { searchParams: Promise<{ etapa?: string }> }) {
  const { supabase, access } = await requireAppContext()
  const sp = await searchParams

  const [{ data: stages }, { data: allCases }] = await Promise.all([
    supabase.from('operational_stages').select('id,code,name,canonical_state,sort_order').eq('is_active', true).order('sort_order'),
    supabase.from('operational_cases').select('id,proposal_id,current_stage_id,canonical_state,entered_stage_at,due_at,pendency_due_at,pendency_reason').order('entered_stage_at', { ascending: true }).limit(500),
  ])
  const cases = (allCases ?? []) as CaseRow[]
  const stage = (stages ?? []).find(s => s.code === sp.etapa)
  const shown = stage ? cases.filter(c => c.current_stage_id === stage.id) : cases.filter(c => !CLOSED.includes(c.canonical_state))

  const ids = shown.map(c => c.proposal_id)
  const { data: proposalRows } = ids.length
    ? await supabase.from('proposals_v2').select('id,external_proposal_id,requested_amount,released_amount,customer_snapshot,commercial_snapshot,seller_id,created_by').in('id', ids)
    : { data: [] as ProposalRow[] }
  const proposals = new Map(((proposalRows ?? []) as ProposalRow[]).map(p => [p.id, p]))
  const sellerIds = [...new Set([...proposals.values()].map(p => p.seller_id).filter(Boolean))] as string[]
  const { data: sellers } = sellerIds.length ? await supabase.from('commercial_sellers').select('id,name').in('id', sellerIds) : { data: [] as { id: string; name: string }[] }
  const sellerName = new Map((sellers ?? []).map(s => [s.id, s.name]))
  const stageName = new Map((stages ?? []).map(s => [s.id, s.name]))
  const count = (id: string) => cases.filter(c => c.current_stage_id === id).length
  const openCount = cases.filter(c => !CLOSED.includes(c.canonical_state)).length

  const now = requestTime()
  const alertOf = (c: CaseRow) => {
    if (c.pendency_due_at && new Date(c.pendency_due_at).getTime() < now) return 'Pendência vencida'
    if (c.pendency_due_at && new Date(c.pendency_due_at).getTime() < now + 86_400_000) return 'Pendência vence em 24h'
    if (c.due_at && !CLOSED.includes(c.canonical_state) && new Date(c.due_at).getTime() < now) return 'Parada além do prazo'
    return ''
  }
  const alerts = shown.filter(c => alertOf(c)).length

  return (
    <section>
      <PageHeader
        title="Esteira"
        description={`${openCount} propostas em andamento${alerts ? ` · ${alerts} com alerta` : ''}`}
        actions={can(access, 'propostas.create') ? <ButtonLink href="/app/propostas/nova"><FilePlus2 size={16} aria-hidden />Nova proposta</ButtonLink> : null}
      />

      <nav aria-label="Etapas" className="mb-4 flex gap-1 overflow-x-auto border-b border-line">
        <Link href="/app/propostas" aria-current={!stage ? 'page' : undefined} className={`-mb-px whitespace-nowrap border-b-2 px-3 py-2.5 text-sm ${!stage ? 'border-brand font-semibold text-ink' : 'border-transparent text-ink-soft hover:text-ink'}`}>
          Em andamento <span className="num ml-1 text-xs text-muted">{openCount}</span>
        </Link>
        {(stages ?? []).map(s => (
          <Link key={s.id} href={`/app/propostas?etapa=${s.code}`} aria-current={stage?.id === s.id ? 'page' : undefined}
            className={`-mb-px whitespace-nowrap border-b-2 px-3 py-2.5 text-sm ${stage?.id === s.id ? 'border-brand font-semibold text-ink' : 'border-transparent text-ink-soft hover:text-ink'}`}>
            {s.name} <span className="num ml-1 text-xs text-muted">{count(s.id)}</span>
          </Link>
        ))}
      </nav>

      <Card className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted">
              <tr>
                <th className="px-3 py-2.5">ADE</th><th className="px-3 py-2.5">Cliente</th><th className="px-3 py-2.5">CPF</th><th className="px-3 py-2.5">Banco / tabela</th>
                <th className="px-3 py-2.5 text-right">Valor</th><th className="px-3 py-2.5">Vendedor</th><th className="px-3 py-2.5">Etapa</th><th className="px-3 py-2.5 text-right">Na etapa</th><th className="px-3 py-2.5">Alerta</th>
              </tr>
            </thead>
            <tbody>
              {shown.map(c => {
                const p = proposals.get(c.proposal_id)
                const cust = (p?.customer_snapshot ?? {}) as Record<string, unknown>
                const com = (p?.commercial_snapshot ?? {}) as Record<string, unknown>
                const d = days(c.entered_stage_at)
                const alert = alertOf(c)
                return (
                  <tr key={c.id} className="border-t border-line-strong/60 hover:bg-surface-muted">
                    <td className="px-3 py-2 font-mono"><Link href={`/app/propostas/${c.proposal_id}`} className="text-brand hover:text-brand-strong">{p?.external_proposal_id ?? '—'}</Link></td>
                    <td className="px-3 py-2 font-medium text-ink"><Link href={`/app/propostas/${c.proposal_id}`} className="hover:text-brand">{String(cust.full_name ?? cust.name ?? 'Cliente')}</Link></td>
                    <td className="px-3 py-2 font-mono text-ink-soft">{formatCpf(String(cust.cpf ?? ''))}</td>
                    <td className="px-3 py-2 text-ink-soft">{[com.bank, com.table].filter(Boolean).join(' · ') || '—'}</td>
                    <td className="num px-3 py-2 text-right text-ink">{brl(p?.released_amount ?? p?.requested_amount ?? null)}</td>
                    <td className="px-3 py-2 text-ink-soft">{(p?.seller_id && sellerName.get(p.seller_id)) || '—'}</td>
                    <td className="px-3 py-2"><Badge tone={STATE_TONE[c.canonical_state] ?? 'neutral'}>{stageName.get(c.current_stage_id) ?? c.canonical_state}</Badge></td>
                    <td className={`num px-3 py-2 text-right ${d >= 4 && !CLOSED.includes(c.canonical_state) ? 'font-semibold text-diverged' : 'text-ink-soft'}`}>{d === 0 ? 'hoje' : `${d} d`}</td>
                    <td className="px-3 py-2 text-xs font-medium text-diverged" title={c.pendency_reason ?? undefined}>{alert}</td>
                  </tr>
                )
              })}
              {shown.length === 0 && <tr><td colSpan={9} className="px-4 py-10 text-center text-sm text-muted">Nenhuma proposta nesta etapa.</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
