import Link from 'next/link'
import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { proposalStatusLabel } from '@/lib/operational'
import { brlText } from '@/lib/receipts/format'
import { PRE_QUEUE_SITUATIONS } from '@/lib/contractStatus'
import { DOCUMENT_LISTS_HREF, versionsWithoutDocumentList } from '@/lib/proposals/checklist'
import { prepareDocuments, sendToDigitization } from './[id]/actions'
import { CancelPreQueue } from './CancelPreQueue'

const primary = 'inline-flex h-8 items-center whitespace-nowrap rounded-[10px] bg-brand px-3 text-xs font-semibold text-white hover:bg-brand-strong'
const money = (v: number | string | null) => (v === null || v === undefined ? '—' : brlText(String(v)))
const PRE_QUEUE = [...PRE_QUEUE_SITUATIONS]

// Proposals that have not entered the typing queue yet (owner, 08/10/2026: "Venda fechada" must never vanish): with the
// next step for each one, and cancel with a reason. They join the board once they enter the Fila de digitação.
export async function PreQueue() {
  const { supabase } = await requireAppContext()
  const { data } = await supabase.from('proposals_v2')
    .select('id,status,customer_id,product_table_version_id,requested_amount,installment_amount,term,created_at')
    .in('status', PRE_QUEUE).order('created_at', { ascending: false }).limit(100)
  const rows = data ?? []
  if (!rows.length) return null
  const { data: clients } = await supabase.from('clients').select('id,full_name').in('id', [...new Set(rows.map(r => r.customer_id))])
  const name = new Map((clients ?? []).map(c => [c.id, c.full_name]))
  // A draft whose bank and agreement have no document list cannot prepare its checklist: say so and where to fix it.
  const noList = await versionsWithoutDocumentList(supabase, rows.filter(r => r.status === 'draft').map(r => r.product_table_version_id))
  return (
    <Card className="mb-4 overflow-hidden">
      <CardHeader title={<span className="flex items-center gap-2">Antes da fila <Badge tone="pending">{rows.length}</Badge></span>} />
      <p className="px-5 pt-1 text-xs text-muted">Propostas criadas que ainda não entraram na Fila de digitação: falta o checklist de documentos, algum documento obrigatório ou o envio.</p>
      <ul className="mt-3 grid gap-2 px-5 pb-5">
        {rows.map(p => {
          const client = name.get(p.customer_id) ?? 'Cliente'
          const created = new Date(p.created_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })
          return (
            <li key={p.id} className="rounded-[12px] border border-line px-4 py-3">
              <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <div className="min-w-[180px] flex-1">
                  <Link href={`/app/propostas/${p.id}`} className="font-medium text-ink hover:text-brand">{client}</Link>
                  <span className="block text-xs text-muted">criada em {created}</span>
                </div>
                <span className="num text-sm text-ink"><span className="text-xs text-muted">Valor </span>{money(p.requested_amount)}</span>
                <span className="num text-sm text-ink"><span className="text-xs text-muted">Parcela </span>{money(p.installment_amount)}</span>
                <span className="num text-sm text-ink"><span className="text-xs text-muted">Prazo </span>{p.term ?? '—'}x</span>
                <Badge tone="pending">{proposalStatusLabel(p.status).label}</Badge>
                <div className="flex flex-wrap gap-2">
                  {p.status === 'draft' && !noList.has(p.product_table_version_id) && <form action={prepareDocuments}><input type="hidden" name="proposal_id" value={p.id} /><input type="hidden" name="back" value="/app/propostas" /><SubmitButton className={primary} pendingText="...">Preparar documentos</SubmitButton></form>}
                  {p.status === 'documents_pending' && <Link href={`/app/propostas/${p.id}`} className={primary}>Anexar documentos</Link>}
                  {p.status === 'ready_for_digitization' && <form action={sendToDigitization}><input type="hidden" name="proposal_id" value={p.id} /><input type="hidden" name="back" value="/app/propostas" /><SubmitButton className={primary} pendingText="...">Enviar para digitação</SubmitButton></form>}
                </div>
              </div>
              {p.status === 'draft' && noList.has(p.product_table_version_id) && (
                <p className="mt-2 rounded-[10px] bg-[#FEF3C7] px-3 py-2 text-xs text-[#92400E]">
                  Parada porque este banco e convênio não têm lista de documentos. Próximo passo: cadastre a lista em{' '}
                  <Link href={DOCUMENT_LISTS_HREF} className="font-medium underline">Cadastros › Documentos por banco</Link> e depois clique em Preparar documentos.
                </p>
              )}
              <CancelPreQueue proposalId={p.id} summary={<>Cancelar a proposta de <strong>{client}</strong>, {money(p.requested_amount)}{p.term ? ` em ${p.term}x` : ''}{p.installment_amount ? ` (parcela ${money(p.installment_amount)})` : ''}, criada em {created}?</>} />
            </li>
          )
        })}
      </ul>
    </Card>
  )
}
