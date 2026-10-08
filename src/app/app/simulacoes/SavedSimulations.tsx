import Link from 'next/link'
import { Badge, Card, CardHeader, type Tone } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { brlText } from '@/lib/receipts/format'
import { createProposalFromSimulation } from './actions'

const SIM_STATUS: Record<string, [string, Tone]> = {
  draft: ['Rascunho', 'neutral'], calculated: ['Calculada', 'pending'], selected: ['Virou proposta', 'received'], expired: ['Expirada', 'neutral'], cancelled: ['Cancelada', 'reversed'],
}
const money = (v: number | string | null | undefined) => (v === null || v === undefined ? '—' : brlText(String(v)))

// Saved simulations (the negotiated offers). customerId: only that client's (the lead panel); back: where the
// "send to the typing queue" returns. Sending creates the proposal from the simulation (the lead follows it).
export async function SavedSimulations({ customerId, back, title = 'Simulações gravadas', sendLabel = 'Enviar para a esteira' }: {
  customerId?: string; back?: string; title?: string; sendLabel?: string
}) {
  const { supabase } = await requireAppContext()
  let q = supabase.from('simulations')
    .select('id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,created_at,clients(full_name)')
    .order('created_at', { ascending: false }).limit(50)
  if (customerId) q = q.eq('customer_id', customerId)
  const [simulationsResult, proposalsResult, tablesResult, versionsResult] = await Promise.all([
    q,
    supabase.from('proposals_v2').select('id,simulation_id').not('simulation_id', 'is', null),
    supabase.from('product_tables').select('id,name,code'),
    supabase.from('product_table_versions').select('id,version,product_table_id').limit(5000),
  ])
  const tableNames = new Map((tablesResult.data ?? []).map(t => [t.id, t.name || t.code]))
  const versionOf = new Map((versionsResult.data ?? []).map(v => [v.id, v]))
  const proposalBySimulation = new Map((proposalsResult.data ?? []).map(p => [p.simulation_id, p.id]))
  const clientName = (s: { clients: { full_name: string } | { full_name: string }[] | null }) => (Array.isArray(s.clients) ? s.clients[0]?.full_name : s.clients?.full_name) ?? 'Cliente'
  return (
      <Card className="overflow-hidden">
        <CardHeader title={<span className="flex items-center gap-2">{title} <Badge tone="neutral">{simulationsResult.data?.length ?? 0}</Badge></span>} />
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="border-y border-line bg-surface-muted text-xs text-muted">
              <tr><th className="px-5 py-2 font-medium">{customerId ? 'Gravada em' : 'Cliente'}</th><th className="px-3 py-2 font-medium">Tabela</th><th className="px-3 py-2 text-right font-medium">Contrato</th><th className="px-3 py-2 text-right font-medium">Liberado</th><th className="px-3 py-2 text-right font-medium">Parcela</th><th className="px-3 py-2 text-right font-medium">Prazo</th><th className="px-3 py-2 font-medium">Situação</th><th className="px-5 py-2" /></tr>
            </thead>
            <tbody>
              {(simulationsResult.data ?? []).map(s => {
                const proposalId = proposalBySimulation.get(s.id)
                const v = versionOf.get(s.product_table_version_id)
                const [st, tone] = SIM_STATUS[s.status] ?? [s.status, 'neutral' as Tone]
                return (
                  <tr key={s.id} className="border-t border-line hover:bg-surface-muted/60">
                    <td className="px-5 py-2.5">{!customerId && <Link href={`/app/clientes/${s.customer_id}`} className="font-medium text-ink hover:text-brand">{clientName(s)}</Link>}<span className={customerId ? 'text-ink-soft' : 'block text-xs text-muted'}>{new Date(s.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span></td>
                    <td className="px-3 py-2.5 text-ink-soft">{v ? `${tableNames.get(v.product_table_id) ?? 'Tabela'} · v${v.version}` : '—'}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(s.requested_amount)}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(s.released_amount ?? s.requested_amount)}</td>
                    <td className="num whitespace-nowrap px-3 py-2.5 text-right font-medium text-ink">{s.installment_amount === null ? 'Não calculada' : money(s.installment_amount)}</td>
                    <td className="num px-3 py-2.5 text-right">{s.term ?? '—'}</td>
                    <td className="px-3 py-2.5"><Badge tone={tone}>{st}</Badge></td>
                    <td className="px-5 py-2.5 text-right">
                      {proposalId
                        ? <Link href={`/app/propostas/${proposalId}`} className="text-sm font-medium text-brand hover:underline">Abrir proposta</Link>
                        : <form action={createProposalFromSimulation}>
                            <input type="hidden" name="simulation_id" value={s.id} />{back && <input type="hidden" name="back" value={back} />}
                            <SubmitButton className="inline-flex h-8 items-center whitespace-nowrap rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong" pendingText="Enviando...">{sendLabel}</SubmitButton>
                          </form>}
                    </td>
                  </tr>
                )
              })}
              {!simulationsResult.data?.length && <tr><td colSpan={8} className="px-5 py-10 text-center text-muted">{customerId ? 'Nenhuma simulação gravada para este cliente. Simule e clique em Usar esta.' : 'Nenhuma simulação gravada ainda.'}</td></tr>}
            </tbody>
          </table>
        </div>
      </Card>
  )
}
