import Link from 'next/link'
import { notFound } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { Badge, Card, CardHeader } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { can } from '@/lib/access'
import { atLeast } from '@/lib/rbac'
import { isUuid } from '@/lib/team'
import { proposalStatusLabel } from '@/lib/operational'
import { fetchAll } from '@/lib/fetchAll'
import { decimalBr } from '@/lib/commission/tableValues'
import { attachDocument, prepareDocuments, sendToDigitization, validateRequirement } from './actions'
import { PipelineCard } from './PipelineCard'
import { CommissionCard } from './CommissionCard'
import { ContractForm } from './ContractForm'
import { HistoryCard } from './HistoryCard'

// "10000.00" -> "10.000,00" (typed back the same way; parsed without floating point).
const decimalInput = (v: string | number | null) => (v === null || v === undefined ? '' : decimalBr(Number.isInteger(v) ? `${v}.00` : String(v), true))

// The contract file (part C2, owner decision 26/09/2026): the contract as a locked form ("Editar contrato"), the
// pipeline, the commission with the payout change, documents, and one history with notes.
export default async function ContractPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  if (!isUuid(id)) notFound()
  const { supabase, membership, access } = await requireAppContext()

  const { data: proposal } = await supabase.from('proposals_v2')
    .select('id,status,customer_id,seller_id,product_table_version_id,requested_amount,released_amount,installment_amount,term,external_proposal_id,customer_snapshot,commercial_snapshot,created_at')
    .eq('id', id).maybeSingle()
  if (!proposal) notFound()

  const [{ data: requirements }, { data: job }, { data: operationalCase }, { data: customerDocuments }, { data: externalIds }, { data: submission }, { data: sellers }, versions, { data: tables }, { data: routes }, { data: banks }] = await Promise.all([
    supabase.from('proposal_document_requirements').select('id,document_type_id,label_snapshot,required_snapshot,status,exception_reason').eq('proposal_id', id).order('created_at'),
    supabase.from('digitization_jobs').select('id,status').eq('proposal_id', id).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    supabase.from('operational_cases').select('id,canonical_state,external_status_raw').eq('proposal_id', id).maybeSingle(),
    supabase.from('customer_documents').select('id,document_type_id,original_file_name,version,status').eq('customer_id', proposal.customer_id).eq('status', 'active').order('created_at', { ascending: false }),
    supabase.from('proposal_external_identities').select('institution_key,external_proposal_number,source,first_seen_at').eq('proposal_id', id).order('first_seen_at'),
    supabase.from('proposal_submissions').select('status,decision_reason').eq('proposal_id', id).maybeSingle(),
    supabase.from('commercial_sellers').select('id,name,code,is_active').order('name'),
    fetchAll<{ id: string; product_table_id: string; version: number }>((a, b) => supabase.from('product_table_versions').select('id,product_table_id,version').eq('status', 'published').order('id').range(a, b)),
    supabase.from('product_tables').select('id,name,route_id,status'),
    supabase.from('organization_product_routes').select('id,org_bank_id'),
    supabase.from('organization_banks').select('id,name'),
  ])

  const customer = (proposal.customer_snapshot ?? {}) as Record<string, unknown>
  const status = proposalStatusLabel(proposal.status)
  const paid = proposal.status === 'paid'
  const closed = ['rejected', 'cancelled'].includes(proposal.status)
  const finance = can(access, 'financeiro.view')
  const manager = atLeast(membership.role, 'manager')
  const canEdit = !closed && (paid ? manager : can(access, 'propostas.edit') || can(access, 'financeiro.edit'))
  const { data: payout } = finance ? await supabase.rpc('contract_payout', { p_proposal: id }) : { data: [] }
  const received = ((payout ?? []) as { locked: boolean }[]).some(p => p.locked)

  // Current published vigência of each active table, as "Banco · Tabela (vN)".
  const tableOf = new Map((tables ?? []).map(t => [t.id, t]))
  const bankOf = new Map((routes ?? []).map(r => [r.id, (banks ?? []).find(b => b.id === r.org_bank_id)?.name ?? '']))
  const latest = new Map<string, { id: string; version: number }>()
  for (const v of versions) { const cur = latest.get(v.product_table_id); if (!cur || v.version > cur.version) latest.set(v.product_table_id, v) }
  const tableOptions = [...latest.entries()].filter(([tid]) => tableOf.get(tid)?.status === 'active').map(([tid, v]) => {
    const t = tableOf.get(tid)!
    return { id: v.id, label: `${bankOf.get(t.route_id) ?? ''} · ${t.name} (v${v.version})` }
  }).sort((a, b) => a.label.localeCompare(b.label, 'pt-BR'))
  // The contract's own vigência stays selectable (and correctly named) even when a newer one was published.
  const own = versions.find(v => v.id === proposal.product_table_version_id)
  if (own && !tableOptions.some(o => o.id === own.id)) {
    const t = tableOf.get(own.product_table_id)
    if (t) tableOptions.unshift({ id: own.id, label: `${bankOf.get(t.route_id) ?? ''} · ${t.name} (v${own.version}, do contrato)` })
  }
  const sellerOptions = (sellers ?? []).filter(s => s.is_active || s.id === proposal.seller_id).map(s => ({ id: s.id, label: `${s.code ? `${String(s.code).padStart(3, '0')} · ` : ''}${s.name}` }))
  const pendingRequired = (requirements ?? []).filter(r => r.required_snapshot && !['validated', 'waived'].includes(r.status))
  const ghost = 'h-9 rounded-[10px] border border-line-strong bg-surface px-3 text-sm text-ink hover:bg-surface-muted'

  return (
    <section>
      <Link href="/app/contratos" className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted hover:text-ink"><ArrowLeft size={15} aria-hidden />Contratos</Link>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="text-sm text-brand">Contrato {proposal.external_proposal_id ? `nº ${proposal.external_proposal_id}` : proposal.id.slice(0, 8)}</div>
          <h1 className="mt-1 text-2xl font-semibold text-ink"><Link href={`/app/clientes/${proposal.customer_id}`} className="hover:text-brand">{String(customer.full_name ?? 'Cliente')}</Link></h1>
          <p className="mt-1 text-sm text-muted">Criado em {new Date(proposal.created_at).toLocaleString('pt-BR')}</p>
        </div>
        <div className="text-right"><Badge tone={paid ? 'received' : closed ? 'neutral' : 'pending'}>{status.label}</Badge><p className="mt-2 max-w-xs text-xs text-muted">{status.next}</p></div>
      </div>

      {submission && submission.status !== 'validated' && (
        <div className="mt-4 rounded-[14px] border border-line bg-surface px-5 py-3 text-sm text-ink">
          {submission.status === 'pending'
            ? <>Enviada pelo portal do corretor e <strong>aguardando validação</strong>: ainda não está na esteira e não tem comissão. <Link href="/app/propostas/validacao" className="text-brand underline">Validar ou recusar</Link></>
            : <>Recusada na validação do portal: {submission.decision_reason}</>}
        </div>
      )}

      <ContractForm c={{
        id: proposal.id, table_version_id: proposal.product_table_version_id, seller_id: proposal.seller_id,
        requested: decimalInput(proposal.requested_amount), released: decimalInput(proposal.released_amount), installment: decimalInput(proposal.installment_amount),
        term: proposal.term ? String(proposal.term) : '', ade: proposal.external_proposal_id,
      }} tables={tableOptions} sellers={sellerOptions} canEdit={canEdit} paid={paid} received={received} />
      <PipelineCard supabase={supabase} access={access} proposalId={proposal.id} />
      <CommissionCard supabase={supabase} access={access} proposalId={proposal.id} closed={closed} canOverride={manager} />

      <div className="mt-4 grid gap-4 xl:grid-cols-2">
        <Card>
          <CardHeader title={<span className="flex items-center gap-2">Documentos <Badge tone={pendingRequired.length ? 'pending' : 'neutral'}>{pendingRequired.length} obrigatório(s) pendente(s)</Badge></span>}
            action={['draft', 'documents_pending'].includes(proposal.status) ? <form action={prepareDocuments}><input type="hidden" name="proposal_id" value={proposal.id} /><SubmitButton className={ghost} pendingText="...">Preparar checklist</SubmitButton></form>
              : proposal.status === 'ready_for_digitization' ? <form action={sendToDigitization}><input type="hidden" name="proposal_id" value={proposal.id} /><SubmitButton className={ghost} pendingText="...">Enviar para digitação</SubmitButton></form> : undefined} />
          <div className="grid gap-2 p-5 pt-3">
            {requirements?.map(r => {
              const compatible = (customerDocuments ?? []).filter(d => d.document_type_id === r.document_type_id)
              return (
                <div key={r.id} className="rounded-[10px] border border-line p-3 text-sm">
                  <div className="flex items-center justify-between gap-3"><span className="text-ink">{r.label_snapshot}{r.required_snapshot ? ' *' : ''}</span><span className="text-xs text-muted">{r.status}</span></div>
                  {!['validated', 'waived'].includes(r.status) && compatible.length > 0 && (
                    <form action={attachDocument} className="mt-2 flex gap-2">
                      <input type="hidden" name="proposal_id" value={proposal.id} /><input type="hidden" name="requirement_id" value={r.id} />
                      <select name="document_id" className="field min-w-0 flex-1" defaultValue=""><option value="" disabled>Selecionar documento</option>{compatible.map(d => <option key={d.id} value={d.id}>{d.original_file_name} · v{d.version}</option>)}</select>
                      <button className={ghost}>Vincular</button>
                    </form>
                  )}
                  {r.status === 'attached' && atLeast(membership.role, 'supervisor') && (
                    <form action={validateRequirement} className="mt-2"><input type="hidden" name="proposal_id" value={proposal.id} /><input type="hidden" name="requirement_id" value={r.id} /><button className="text-xs font-medium text-brand">Validar documento</button></form>
                  )}
                </div>
              )
            })}
            {!requirements?.length && <p className="text-sm text-muted">Checklist ainda não preparado para este contrato.</p>}
          </div>
        </Card>
        <Card>
          <CardHeader title="Operação" />
          <dl className="grid gap-3 p-5 pt-3 text-sm">
            <div><dt className="text-xs text-muted">Fila de digitação</dt><dd className="text-ink">{job?.status ?? 'Ainda não enviada'}</dd></div>
            <div><dt className="text-xs text-muted">Status no banco</dt><dd className="text-ink">{operationalCase?.external_status_raw ?? '—'}</dd></div>
            <div><dt className="text-xs text-muted">Números no banco</dt><dd className="text-ink">{externalIds?.length ? externalIds.map(x => `${x.external_proposal_number} (${x.institution_key})`).join(', ') : '—'}</dd></div>
          </dl>
        </Card>
      </div>

      <HistoryCard supabase={supabase} proposalId={proposal.id} />
    </section>
  )
}
