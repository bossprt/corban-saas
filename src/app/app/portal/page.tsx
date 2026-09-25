import Link from 'next/link'
import { redirect } from 'next/navigation'
import { FilePlus2 } from 'lucide-react'
import { Badge, ButtonLink, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { add, fromDecimalString, mul, toDecimalString, type Rational } from '@/lib/commission/money'
import { proposalStatusLabel } from '@/lib/operational'
import { isPortalUser, SUBMISSION_LABEL } from '@/lib/portal'
import { brlText } from '@/lib/receipts/format'

type Submission = { proposal_id: string; status: string; decision_reason: string | null; created_at: string }
type Proposal = { id: string; status: string; customer_snapshot: { full_name?: string } | null; commercial_snapshot: { bank?: string; table?: string } | null; requested_amount: string | null; released_amount: string | null; term: number | null }
type Mine = { mine?: boolean; lines?: { amount: string; multiplier: number }[] }
type Summary = { balance: string; available: string; model: string }
const TONE: Record<string, Tone> = { pending: 'pending', validated: 'received', rejected: 'reversed' }
const ZERO = fromDecimalString('0')

// Broker home (F7): my proposals and what I am going to earn. Everything comes from rows the database lets this broker see.
export default async function PortalHomePage() {
  const { supabase, organization, access, modules } = await requireAppContext()
  if (!isPortalUser(access?.roleKey, modules)) redirect('/app/hoje')

  const [{ data: subRows }, { data: summaryRows }] = await Promise.all([
    supabase.from('proposal_submissions').select('proposal_id,status,decision_reason,created_at').order('created_at', { ascending: false }).limit(100),
    supabase.rpc('payout_account_summaries', { p_org: organization.id }),
  ])
  const subs = (subRows ?? []) as Submission[]
  const ids = subs.map(s => s.proposal_id)
  const { data: proposalRows } = ids.length
    ? await supabase.from('proposals_v2').select('id,status,customer_snapshot,commercial_snapshot,requested_amount,released_amount,term').in('id', ids)
    : { data: [] as Proposal[] }
  const proposals = new Map(((proposalRows ?? []) as Proposal[]).map(p => [p.id, p]))

  // Expected earnings: my own share of the validated proposals (the calculation is frozen on each proposal).
  const validated = subs.filter(s => s.status === 'validated').slice(0, 50)
  const shares = await Promise.all(validated.map(async s => {
    const { data } = await supabase.rpc('proposal_commission_mine', { p_proposal: s.proposal_id })
    const mine = data as Mine | null
    return (mine?.lines ?? []).reduce((acc, l) => add(acc, mul(fromDecimalString(String(l.amount)), fromDecimalString(String(l.multiplier)))), ZERO as Rational)
  }))
  const expected = shares.reduce((acc, v) => add(acc, v), ZERO as Rational)
  const account = ((summaryRows ?? []) as Summary[])[0]
  const count = (st: string) => subs.filter(s => s.status === st).length

  return (
    <section>
      <PageHeader title="Minhas propostas" description="Envie propostas, acompanhe a validação e veja quanto você vai ganhar." />
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Aguardando validação" value={String(count('pending'))} />
        <Stat label="Validadas" value={String(count('validated'))} />
        <Stat label="Comissão prevista" value={brlText(toDecimalString(expected, 2))} hint="sua parte nas propostas validadas" />
        <Stat label="Saldo do extrato" value={account ? brlText(account.balance) : '—'} hint={account?.model === 'account' ? `disponível ${brlText(account.available)}` : 'liberado após o banco pagar'} />
      </div>
      <ButtonLink href="/app/portal/nova" className="mb-4 w-full sm:w-auto"><FilePlus2 size={16} aria-hidden />Enviar nova proposta</ButtonLink>
      <Card className="overflow-hidden">
        <CardHeader title="Propostas enviadas" />
        <ul className="mt-3 text-sm">
          {subs.map(s => {
            const p = proposals.get(s.proposal_id)
            const situation = s.status === 'validated' && p ? proposalStatusLabel(p.status).label : SUBMISSION_LABEL[s.status]
            return (
              <li key={s.proposal_id} className="border-t border-line">
                <Link href={`/app/portal/propostas/${s.proposal_id}`} className="block px-5 py-3 hover:bg-surface-muted">
                  <div className="flex items-center justify-between gap-3">
                    <span className="font-medium text-ink">{p?.customer_snapshot?.full_name ?? 'Cliente'}</span>
                    <Badge tone={TONE[s.status] ?? 'neutral'}>{situation}</Badge>
                  </div>
                  <div className="mt-0.5 text-xs text-muted">
                    {p?.commercial_snapshot?.bank} · {p?.commercial_snapshot?.table} · <span className="num">{brlText(p?.released_amount ?? p?.requested_amount)}</span>{p?.term ? ` em ${p.term}x` : ''} · {new Date(s.created_at).toLocaleDateString('pt-BR')}
                  </div>
                  {s.status === 'rejected' && s.decision_reason && <div className="mt-1 text-xs text-[#991B1B]">Motivo: {s.decision_reason}</div>}
                </Link>
              </li>
            )
          })}
          {!subs.length && <li className="px-5 py-8 text-center text-muted">Nenhuma proposta enviada ainda.</li>}
        </ul>
      </Card>
    </section>
  )
}

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-[14px] border border-line bg-surface px-4 py-3">
      <div className="text-[12px] text-muted">{label}</div>
      <div className="num mt-1 text-xl font-semibold text-ink">{value}</div>
      {hint && <div className="mt-0.5 text-[11px] text-muted">{hint}</div>}
    </div>
  )
}
