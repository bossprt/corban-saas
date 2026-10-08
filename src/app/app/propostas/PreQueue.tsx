import Link from 'next/link'
import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { proposalStatusLabel } from '@/lib/operational'
import { brlText } from '@/lib/receipts/format'
import { cancelBeforeQueue, prepareDocuments, sendToDigitization } from './[id]/actions'

const ghost = 'inline-flex h-8 items-center whitespace-nowrap rounded-[10px] border border-line bg-surface px-3 text-xs font-medium text-ink hover:bg-surface-muted'
const primary = 'inline-flex h-8 items-center whitespace-nowrap rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong'
const money = (v: number | string | null) => (v === null || v === undefined ? '—' : brlText(String(v)))
const PRE_QUEUE = ['draft', 'documents_pending', 'ready_for_digitization']

// Proposals that have not entered the typing queue yet (owner, 08/10/2026: "Venda fechada" must never vanish): with the
// next step for each one, and cancel with a reason. They join the board once they enter the Fila de digitação.
export async function PreQueue() {
  const { supabase } = await requireAppContext()
  const { data } = await supabase.from('proposals_v2')
    .select('id,status,customer_id,requested_amount,installment_amount,term,created_at')
    .in('status', PRE_QUEUE).order('created_at', { ascending: false }).limit(100)
  const rows = data ?? []
  if (!rows.length) return null
  const { data: clients } = await supabase.from('clients').select('id,full_name').in('id', [...new Set(rows.map(r => r.customer_id))])
  const name = new Map((clients ?? []).map(c => [c.id, c.full_name]))
  return (
    <Card className="mb-4 overflow-hidden">
      <CardHeader title={<span className="flex items-center gap-2">Antes da fila <Badge tone="pending">{rows.length}</Badge></span>} />
      <p className="px-5 pt-1 text-xs text-muted">Propostas criadas que ainda não entraram na Fila de digitação: falta o checklist de documentos, algum documento obrigatório ou o envio.</p>
      <div className="mt-2 overflow-x-auto">
        <table className="w-full min-w-[760px] text-left text-sm">
          <thead className="border-y border-line bg-surface-muted text-xs text-muted">
            <tr><th className="px-5 py-2 font-medium">Cliente</th><th className="px-3 py-2 text-right font-medium">Valor</th><th className="px-3 py-2 text-right font-medium">Parcela</th><th className="px-3 py-2 text-right font-medium">Prazo</th><th className="px-3 py-2 font-medium">Situação</th><th className="px-5 py-2" /></tr>
          </thead>
          <tbody>
            {rows.map(p => (
              <tr key={p.id} className="border-t border-line align-top">
                <td className="px-5 py-2.5"><Link href={`/app/propostas/${p.id}`} className="font-medium text-ink hover:text-brand">{name.get(p.customer_id) ?? 'Cliente'}</Link>
                  <span className="block text-xs text-muted">{new Date(p.created_at).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span></td>
                <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(p.requested_amount)}</td>
                <td className="num whitespace-nowrap px-3 py-2.5 text-right">{money(p.installment_amount)}</td>
                <td className="num px-3 py-2.5 text-right">{p.term ?? '—'}</td>
                <td className="px-3 py-2.5"><Badge tone="pending">{proposalStatusLabel(p.status).label}</Badge></td>
                <td className="px-5 py-2.5">
                  <div className="flex flex-wrap justify-end gap-2">
                    {p.status === 'draft' && <form action={prepareDocuments}><input type="hidden" name="proposal_id" value={p.id} /><input type="hidden" name="back" value="/app/propostas" /><SubmitButton className={primary} pendingText="...">Preparar documentos</SubmitButton></form>}
                    {p.status === 'documents_pending' && <Link href={`/app/propostas/${p.id}`} className={primary}>Anexar documentos</Link>}
                    {p.status === 'ready_for_digitization' && <form action={sendToDigitization}><input type="hidden" name="proposal_id" value={p.id} /><input type="hidden" name="back" value="/app/propostas" /><SubmitButton className={primary} pendingText="...">Enviar para digitação</SubmitButton></form>}
                    <details className="relative">
                      <summary className={`${ghost} list-none text-[#B91C1C]`}>Cancelar</summary>
                      <form action={cancelBeforeQueue} className="absolute right-0 z-10 mt-1 grid w-64 gap-2 rounded-[10px] border border-line bg-surface p-3 shadow-lg">
                        <input type="hidden" name="proposal_id" value={p.id} /><input type="hidden" name="back" value="/app/propostas" />
                        <input name="reason" required minLength={3} maxLength={300} placeholder="Motivo (ex.: era teste)" className="field" />
                        <SubmitButton className={`${ghost} justify-center text-[#B91C1C]`} pendingText="Cancelando...">Cancelar proposta</SubmitButton>
                      </form>
                    </details>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Card>
  )
}
