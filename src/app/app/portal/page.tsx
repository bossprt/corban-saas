import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ChevronRight, FilePlus2 } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { fromDecimalString, toDecimalString } from '@/lib/commission/money'
import { proposalStatusLabel } from '@/lib/operational'
import { isPortalUser, SUBMISSION_LABEL } from '@/lib/portal'
import { brlText } from '@/lib/receipts/format'

type Num = string | number
type Submission = { proposal_id: string; status: string; decision_reason: string | null; created_at: string }
type Proposal = { id: string; status: string; customer_snapshot: { full_name?: string } | null; commercial_snapshot: { bank?: string; table?: string } | null; requested_amount: string | null; released_amount: string | null; term: number | null }
type Board = { seller: boolean; expected?: Num; released?: Num; received_month?: Num }
type Contract = {
  id: string; client: string | null; ade: string | null; bank: string | null; table: string | null; term: number | null; amount: Num
  status: string; stage: string | null; paid_to_client_on: string | null; created_at: string; by_me: boolean
  payable: Num; calculated: boolean; waiting: string | null; paid_on: string | null
}
const TONE: Record<string, Tone> = { pending: 'pending', validated: 'received', rejected: 'reversed' }
const money = (v: Num | null | undefined) => brlText(toDecimalString(fromDecimalString(String(v ?? 0)), 2))
const dateBr = (d: string) => new Date(d.length === 10 ? `${d}T12:00:00Z` : d).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })
// Where the broker's share stands, in their words.
function shareState(c: Contract): { text: string; tone: Tone } {
  if (c.paid_on) return { text: `recebido em ${dateBr(c.paid_on)}`, tone: 'received' }
  if (c.status === 'cancelled' || c.status === 'rejected') return { text: 'contrato cancelado', tone: 'reversed' }
  if (!c.calculated) return { text: 'comissão ainda não calculada', tone: 'neutral' }
  switch (c.waiting) {
    case 'client': return { text: 'aguardando pagamento ao cliente', tone: 'neutral' }
    case 'physical': return { text: 'aguardando o físico', tone: 'pending' }
    case 'bank': return { text: 'aguardando comissão do banco', tone: 'pending' }
    case 'divergent': return { text: 'comissão do banco em análise', tone: 'pending' }
    case 'no_payout': return { text: 'sem comissão para você', tone: 'neutral' }
    case null: return { text: 'liberado, entra no próximo pagamento', tone: 'brand' }
    default: return { text: 'em andamento', tone: 'neutral' }
  }
}

// Broker home (F7; 06/10/2026: every contract where they are the seller, also the ones the company typed for them).
// What I will earn, my contracts with my share, and the proposals I sent that still wait for the company.
export default async function PortalHomePage() {
  const { supabase, organization, access, modules } = await requireAppContext()
  if (!isPortalUser(access?.roleKey, modules)) redirect('/app/hoje')

  const [{ data: subRows }, { data: boardData }, { data: contractRows }] = await Promise.all([
    supabase.from('proposal_submissions').select('proposal_id,status,decision_reason,created_at').neq('status', 'validated').order('created_at', { ascending: false }).limit(100),
    supabase.rpc('seller_dashboard', { p_org: organization.id }),
    supabase.rpc('seller_contracts', { p_org: organization.id }),
  ])
  const subs = (subRows ?? []) as Submission[]
  const ids = subs.map(s => s.proposal_id)
  const { data: proposalRows } = ids.length
    ? await supabase.from('proposals_v2').select('id,status,customer_snapshot,commercial_snapshot,requested_amount,released_amount,term').in('id', ids)
    : { data: [] as Proposal[] }
  const proposals = new Map(((proposalRows ?? []) as Proposal[]).map(p => [p.id, p]))
  const board = (boardData ?? { seller: false }) as Board
  const contracts = (Array.isArray(contractRows) ? contractRows : []) as Contract[]
  const pending = subs.filter(s => s.status === 'pending').length

  return (
    <section>
      <PageHeader title="Meu portal" description="Seus contratos, quanto você vai ganhar e as propostas que você enviou." />
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Previsto" value={money(board.expected)} hint="sua parte nos contratos em andamento" />
        <Stat label="Liberado" value={money(board.released)} hint="entra no próximo pagamento" tone="text-[#1D6E4F]" />
        <Stat label="Recebido no mês" value={money(board.received_month)} hint="já pago a você" />
        <Stat label="Propostas aguardando" value={String(pending)} hint="enviadas, a empresa vai validar" />
      </div>
      <div className="mb-4 flex flex-wrap gap-2">
        <ButtonLink href="/app/portal/nova" className="w-full sm:w-auto"><FilePlus2 size={16} aria-hidden />Enviar nova proposta</ButtonLink>
        <Link href="/app/repasse" className="inline-flex h-10 w-full items-center justify-center rounded-[10px] border border-line-strong bg-surface px-4 text-sm text-ink hover:bg-surface-muted sm:w-auto">Ver meu extrato</Link>
      </div>

      <Card className="mb-4 overflow-hidden">
        <CardHeader title={<span className="flex items-center gap-2">Meus contratos <Badge tone="neutral">{contracts.length}</Badge></span>} />
        <ul className="mt-3 text-sm">
          {contracts.map(c => {
            const st = shareState(c)
            const situation = c.status === 'paid' ? `Pago ao cliente${c.paid_to_client_on ? ` em ${dateBr(c.paid_to_client_on)}` : ''}` : c.stage ?? proposalStatusLabel(c.status).label
            return (
              <li key={c.id} className="border-t border-line">
                <Link href={`/app/portal/propostas/${c.id}`} className="flex items-center justify-between gap-3 px-5 py-3 hover:bg-surface-muted">
                  <span className="min-w-0">
                    <span className="block truncate font-medium text-ink">{c.client ?? 'Cliente'}{c.ade ? <span className="font-normal text-muted"> · nº {c.ade}</span> : null}</span>
                    <span className="block truncate text-xs text-muted">{[c.bank, c.table].filter(Boolean).join(' · ')}{c.bank || c.table ? ' · ' : ''}<span className="num">{money(c.amount)}</span>{c.term ? ` em ${c.term}x` : ''} · {situation}{c.by_me ? '' : ' · digitado pela empresa'}</span>
                  </span>
                  <span className="shrink-0 text-right">
                    <span className="num block text-sm font-semibold text-ink">{c.calculated ? money(c.payable) : '—'}</span>
                    <Badge tone={st.tone} className="mt-0.5">{st.text}</Badge>
                  </span>
                  <ChevronRight size={16} aria-hidden className="shrink-0 text-muted" />
                </Link>
              </li>
            )
          })}
          {!contracts.length && <li className="px-5 py-8 text-center text-muted">Nenhum contrato em seu nome ainda.</li>}
        </ul>
      </Card>

      <Card className="overflow-hidden">
        <CardHeader title="Propostas enviadas: aguardando ou recusadas" />
        <ul className="mt-3 text-sm">
          {subs.map(s => {
            const p = proposals.get(s.proposal_id)
            return (
              <li key={s.proposal_id} className="border-t border-line">
                <Link href={`/app/portal/propostas/${s.proposal_id}`} className="block px-5 py-3 hover:bg-surface-muted">
                  <div className="flex items-center justify-between gap-3">
                    <span className="font-medium text-ink">{p?.customer_snapshot?.full_name ?? 'Cliente'}</span>
                    <Badge tone={TONE[s.status] ?? 'neutral'}>{SUBMISSION_LABEL[s.status]}</Badge>
                  </div>
                  <div className="mt-0.5 text-xs text-muted">
                    {p?.commercial_snapshot?.bank} · {p?.commercial_snapshot?.table} · <span className="num">{brlText(p?.released_amount ?? p?.requested_amount)}</span>{p?.term ? ` em ${p.term}x` : ''} · {new Date(s.created_at).toLocaleDateString('pt-BR')}
                  </div>
                  {s.status === 'rejected' && s.decision_reason && <div className="mt-1 text-xs text-[#991B1B]">Motivo: {s.decision_reason}</div>}
                </Link>
              </li>
            )
          })}
          {!subs.length && <li className="px-5 py-8 text-center text-muted">Nenhuma proposta aguardando. As validadas aparecem em Meus contratos.</li>}
        </ul>
      </Card>
    </section>
  )
}

function Stat({ label, value, hint, tone }: { label: string; value: string; hint?: string; tone?: string }) {
  return (
    <div className="rounded-[14px] border border-line bg-surface px-4 py-3">
      <div className="text-[12px] text-muted">{label}</div>
      <div className={`num mt-1 whitespace-nowrap text-lg font-semibold sm:text-xl ${tone ?? 'text-ink'}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[11px] text-muted">{hint}</div>}
    </div>
  )
}
