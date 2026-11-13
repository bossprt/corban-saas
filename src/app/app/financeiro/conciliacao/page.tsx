import Link from 'next/link'
import { Badge, Card, CardHeader, PageHeader } from '@/components/ui'
import { can } from '@/lib/access'
import { requireAppContext } from '@/lib/appContext'
import { brlText } from '@/lib/receipts/format'
import { acceptDivergence } from '../actions'

type OpenItem = { id: string; entry_kind: string; component_key: string | null; installment_number: number | null; amount: string; expected_amount: string | null }
type Row = {
  proposal_id: string; reference: string; client: string; term: number | null; upfront: string; deferred: string; deferred_count: number
  gratification: string; chargeback: string; net: string; open_items: OpenItem[]; total_count: number
  sum_upfront: string; sum_deferred: string; sum_gratification: string; sum_chargeback: string; sum_net: string
}
const PAGE = 50

// Contract by contract: what the ledger received (upfront, deferred installments, chargebacks) and the divergences still open.
// Computed in the database (06/11/2026): the period filters received_on there, the list is paged and the totals cover the
// whole filter, not only the page.
export default async function ReconciliationPage({ searchParams }: { searchParams: Promise<{ ver?: string; de?: string; ate?: string; pagina?: string }> }) {
  const sp = await searchParams
  // Dashboard "Recebido dos bancos": only what was received in the period (received_on), every contract.
  const isDate = (v?: string) => !!v && /^\d{4}-\d{2}-\d{2}$/.test(v)
  const de = isDate(sp.de) ? sp.de! : '', ate = isDate(sp.ate) ? sp.ate! : ''
  const ver = de || ate ? 'todas' : (sp.ver === 'todas' ? 'todas' : 'abertas')
  const page = Math.max(1, Math.min(10_000, Number.parseInt(sp.pagina ?? '1', 10) || 1))
  const { supabase, organization, access } = await requireAppContext()
  if (!can(access, 'financeiro.view')) return <section><PageHeader title="Conciliação" /><Card className="p-5 text-sm text-ink-soft">Seu perfil não vê o financeiro.</Card></section>
  const { data, error } = await supabase.rpc('commission_reconciliation', {
    p_org: organization.id, p_from: de || null, p_to: ate || null, p_only_open: ver === 'abertas', p_limit: PAGE, p_offset: (page - 1) * PAGE,
  })
  const list = (data ?? []) as Row[]
  const total = list[0]?.total_count ?? 0
  const pages = Math.max(1, Math.ceil(total / PAGE))
  const canAccept = can(access, 'financeiro.approve')
  const qs = (extra: Record<string, string>) => `?${new URLSearchParams(Object.entries({ ver, de, ate, ...extra }).filter(([, v]) => v)).toString()}`
  const sums = list[0]

  return (
    <section>
      <PageHeader title="Conciliação por contrato" description="O que cada contrato já recebeu do banco ou da promotora, e as divergências ainda em aberto."
        actions={<Link href="/app/financeiro" className="text-sm text-brand hover:underline">Voltar ao financeiro</Link>} />
      {(de || ate) && <p className="mb-4 flex flex-wrap items-center gap-2 rounded-[10px] border border-line bg-surface-muted px-4 py-2 text-sm">
        <span className="text-ink-soft">Recebido {de && `de ${de.split('-').reverse().join('/')} `}{ate && `até ${ate.split('-').reverse().join('/')}`}</span>
        <Link href="?ver=todas" className="text-brand hover:underline">Ver tudo</Link></p>}
      {error && <p role="alert" className="mb-4 rounded-[10px] bg-[#FDF3DC] px-4 py-2 text-sm text-[#92400E]">Não foi possível carregar a conciliação agora. Tente de novo em instantes.</p>}
      <Card className="overflow-hidden">
        <CardHeader title={ver === 'todas' ? 'Todos os contratos com recebimento' : 'Contratos com divergência em aberto'} action={
          <nav className="flex gap-1 text-[13px]">
            {[['abertas', 'Divergências em aberto'], ['todas', 'Todos']].map(([k, label]) => <Link key={k} href={`?ver=${k}`} className={`rounded-md px-2 py-1 ${ver === k ? 'bg-brand-soft font-semibold text-brand-strong' : 'text-ink-soft hover:bg-surface-muted'}`}>{label}</Link>)}
          </nav>
        } />
        <div className="overflow-x-auto">
          <table className="w-full text-left text-[13px]">
            <thead className="bg-surface-muted text-xs font-semibold text-muted"><tr>
              <th className="px-3 py-2">Contrato</th><th className="px-3 py-2 text-right">À vista</th><th className="px-3 py-2 text-right">Diferido</th><th className="px-3 py-2 text-right">Gratificação</th><th className="px-3 py-2 text-right">Estornos</th><th className="px-3 py-2 text-right">Líquido recebido</th><th className="px-3 py-2">Divergências</th>
            </tr></thead>
            <tbody>
              {list.map(r => (
                <tr key={r.proposal_id} className="border-t border-line align-top">
                  <td className="px-3 py-2"><Link href={`/app/propostas/${r.proposal_id}`} className="font-medium text-ink hover:underline">{r.reference || 'Proposta'}</Link><div className="text-xs text-muted">{r.client}</div></td>
                  <td className="num px-3 py-2 text-right">{brlText(r.upfront)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(r.deferred)}<div className="text-xs text-muted">{r.deferred_count}{r.term ? ` de ${r.term}` : ''} parcela(s)</div></td>
                  <td className="num px-3 py-2 text-right">{brlText(r.gratification)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(r.chargeback)}</td>
                  <td className="num px-3 py-2 text-right font-semibold">{brlText(r.net)}</td>
                  <td className="px-3 py-2">
                    {r.open_items.length === 0 ? <Badge tone="received">Nenhuma</Badge> : r.open_items.map(e => (
                      <div key={e.id} className="mb-2">
                        <div><Badge tone="diverged">{e.entry_kind === 'chargeback' ? 'Estorno' : e.component_key === 'deferred' ? `Parcela ${e.installment_number}` : e.component_key === 'gratification' ? 'Gratificação' : e.component_key === 'bonus' ? 'Bônus' : 'À vista'}</Badge>
                          <span className="num ml-2">recebido {brlText(e.amount)} · esperado {brlText(e.expected_amount)}</span></div>
                        {canAccept && (
                          <form action={acceptDivergence} className="mt-1 flex gap-1"><input type="hidden" name="receipt_id" value={e.id} />
                            <input name="note" required minLength={3} placeholder="Motivo para aceitar" className="field h-8 w-48 text-xs" /><button className="h-8 rounded-md border border-line px-2 text-xs hover:bg-surface-muted">Aceitar</button></form>
                        )}
                      </div>
                    ))}
                  </td>
                </tr>
              ))}
              {!list.length && <tr><td colSpan={7} className="px-3 py-8 text-center text-muted">{ver === 'todas' ? 'Nenhum recebimento lançado ainda.' : 'Nenhuma divergência em aberto.'}</td></tr>}
            </tbody>
            {sums && (
              <tfoot className="border-t-2 border-line-strong bg-surface-muted font-semibold">
                <tr>
                  <td className="px-3 py-2">Total ({total} contrato{total === 1 ? '' : 's'})</td>
                  <td className="num px-3 py-2 text-right">{brlText(sums.sum_upfront)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(sums.sum_deferred)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(sums.sum_gratification)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(sums.sum_chargeback)}</td>
                  <td className="num px-3 py-2 text-right">{brlText(sums.sum_net)}</td>
                  <td className="px-3 py-2" />
                </tr>
              </tfoot>
            )}
          </table>
        </div>
        {pages > 1 && (
          <nav aria-label="Páginas" className="flex items-center justify-between gap-2 border-t border-line px-4 py-3 text-sm">
            <span className="text-ink-soft">Página {page} de {pages}</span>
            <span className="flex gap-2">
              {page > 1 && <Link href={qs({ pagina: String(page - 1) })} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Anterior</Link>}
              {page < pages && <Link href={qs({ pagina: String(page + 1) })} className="rounded-md border border-line px-3 py-1 hover:bg-surface-muted">Próxima</Link>}
            </span>
          </nav>
        )}
      </Card>
    </section>
  )
}
