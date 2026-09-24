import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { add, fromDecimalString, sub, toDecimalString, type Rational } from '@/lib/commission/money'
import { brlText } from '@/lib/receipts/format'
import { acceptDivergence } from '../actions'

type Entry = { id: string; proposal_id: string; entry_kind: string; component_key: string | null; installment_number: number | null; amount: string; expected_amount: string | null; reconciliation: string; received_on: string | null; created_at: string }
const ZERO = fromDecimalString('0')
const dec = (v: string | number | null) => fromDecimalString(String(v ?? '0'))

// Contract by contract: what the ledger received (upfront, deferred installments, chargebacks) and the divergences still open.
export default async function ReconciliationPage({ searchParams }: { searchParams: Promise<{ ver?: string }> }) {
  const { ver = 'abertas' } = await searchParams
  const { supabase, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Conciliação" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const [{ data: entryRows }, { data: resolutions }] = await Promise.all([
    supabase.from('commission_receipts').select('id,proposal_id,entry_kind,component_key,installment_number,amount,expected_amount,reconciliation,received_on,created_at').order('created_at', { ascending: false }).limit(5000),
    supabase.from('commission_receipt_resolutions').select('receipt_id,note'),
  ])
  const entries = (entryRows ?? []) as Entry[]
  const accepted = new Map((resolutions ?? []).map(r => [r.receipt_id, r.note]))
  const proposalIds = [...new Set(entries.map(e => e.proposal_id))]
  const { data: proposals } = proposalIds.length ? await supabase.from('proposals_v2').select('id,external_proposal_id,customer_snapshot,term').in('id', proposalIds) : { data: [] }
  const byId = new Map((proposals ?? []).map(p => [p.id, p]))

  type Row = { id: string; upfront: Rational; deferred: Rational; deferredCount: number; chargeback: Rational; open: Entry[] }
  const rows = new Map<string, Row>()
  for (const e of entries) {
    const r = rows.get(e.proposal_id) ?? { id: e.proposal_id, upfront: ZERO, deferred: ZERO, deferredCount: 0, chargeback: ZERO, open: [] }
    if (e.entry_kind === 'chargeback') r.chargeback = add(r.chargeback, dec(e.amount))
    else if (e.component_key === 'deferred') { r.deferred = add(r.deferred, dec(e.amount)); r.deferredCount++ }
    else r.upfront = add(r.upfront, dec(e.amount))
    if (e.reconciliation === 'divergent' && !accepted.has(e.id)) r.open.push(e)
    rows.set(e.proposal_id, r)
  }
  const list = [...rows.values()].filter(r => ver === 'todas' || r.open.length > 0)
  const canAccept = can(access, 'financeiro.approve')

  return (
    <section>
      <PageHeader title="Conciliação por contrato" description="O que cada contrato já recebeu do banco ou da promotora, e as divergências ainda em aberto."
        actions={<Link href="/app/financeiro" className="text-sm text-brand hover:underline">Voltar ao financeiro</Link>} />
      <Card className="overflow-hidden">
        <CardHeader title={ver === 'todas' ? 'Todos os contratos com recebimento' : 'Contratos com divergência em aberto'} action={
          <nav className="flex gap-1 text-[13px]">
            {[['abertas', 'Divergências em aberto'], ['todas', 'Todos']].map(([k, label]) => <Link key={k} href={`?ver=${k}`} className={`rounded-md px-2 py-1 ${ver === k ? 'bg-brand-soft font-semibold text-brand-strong' : 'text-ink-soft hover:bg-surface-muted'}`}>{label}</Link>)}
          </nav>
        } />
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr>
              <th className="px-3 py-2">Contrato</th><th className="px-3 py-2 text-right">À vista</th><th className="px-3 py-2 text-right">Diferido</th><th className="px-3 py-2 text-right">Estornos</th><th className="px-3 py-2 text-right">Líquido recebido</th><th className="px-3 py-2">Divergências</th>
            </tr></thead>
            <tbody>
              {list.map(r => {
                const p = byId.get(r.id)
                const net = sub(add(r.upfront, r.deferred), r.chargeback)
                return (
                  <tr key={r.id} className="border-t border-line align-top">
                    <td className="px-3 py-2"><Link href={`/app/propostas/${r.id}`} className="font-medium text-ink hover:underline">{p?.external_proposal_id ?? 'Proposta'}</Link><div className="text-xs text-muted">{(p?.customer_snapshot as { full_name?: string } | null)?.full_name ?? ''}</div></td>
                    <td className="num px-3 py-2 text-right">{brlText(toDecimalString(r.upfront, 2))}</td>
                    <td className="num px-3 py-2 text-right">{brlText(toDecimalString(r.deferred, 2))}<div className="text-xs text-muted">{r.deferredCount}{p?.term ? ` de ${p.term}` : ''} parcela(s)</div></td>
                    <td className="num px-3 py-2 text-right">{brlText(toDecimalString(r.chargeback, 2))}</td>
                    <td className="num px-3 py-2 text-right font-semibold">{brlText(toDecimalString(net, 2))}</td>
                    <td className="px-3 py-2">
                      {r.open.length === 0 ? <Badge tone="received">Nenhuma</Badge> : r.open.map(e => (
                        <div key={e.id} className="mb-2">
                          <div><Badge tone="diverged">{e.entry_kind === 'chargeback' ? 'Estorno' : e.component_key === 'deferred' ? `Parcela ${e.installment_number}` : 'À vista'}</Badge>
                            <span className="num ml-2">recebido {brlText(e.amount)} · esperado {brlText(e.expected_amount)}</span></div>
                          {canAccept && (
                            <form action={acceptDivergence} className="mt-1 flex gap-1"><input type="hidden" name="receipt_id" value={e.id} />
                              <input name="note" required minLength={3} placeholder="Motivo para aceitar" className="field h-8 w-48 text-xs" /><button className="h-8 rounded-md border border-line px-2 text-xs hover:bg-surface-muted">Aceitar</button></form>
                          )}
                        </div>
                      ))}
                    </td>
                  </tr>
                )
              })}
              {!list.length && <tr><td colSpan={6} className="px-3 py-8 text-center text-muted">{ver === 'todas' ? 'Nenhum recebimento lançado ainda.' : 'Nenhuma divergência em aberto.'}</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
    </section>
  )
}
