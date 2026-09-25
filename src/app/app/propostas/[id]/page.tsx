import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { attachDocument, prepareDocuments, sendToDigitization, validateRequirement } from './actions'
import { atLeast } from '@/lib/rbac'
import { proposalStatusLabel } from '@/lib/operational'
import { PipelineCard } from './PipelineCard'
import { CommissionCard } from './CommissionCard'

function brl(value: number | string | null) {
  return value === null ? 'Não calculado' : Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

export default async function ProposalDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const { supabase, membership, access } = await requireAppContext()

  const { data: proposal } = await supabase.from('proposals_v2')
    .select('id,status,customer_id,simulation_id,requested_amount,released_amount,installment_amount,term,rate,customer_snapshot,commercial_snapshot,created_at')
    .eq('id', id).maybeSingle()

  if (!proposal) notFound()

  const [{ data: requirements }, { data: job }, { data: operationalCase }, { data: customerDocuments }, { data: externalIds }, { data: submission }] = await Promise.all([
    supabase.from('proposal_document_requirements')
      .select('id,document_type_id,label_snapshot,required_snapshot,status,exception_reason')
      .eq('proposal_id', id).order('created_at'),
    supabase.from('digitization_jobs')
      .select('id,status,priority,assigned_to,queued_at,submitted_at,last_error')
      .eq('proposal_id', id).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    supabase.from('operational_cases')
      .select('id,canonical_state,external_status_raw,entered_stage_at,due_at')
      .eq('proposal_id', id).maybeSingle(),
    supabase.from('customer_documents')
      .select('id,document_type_id,original_file_name,version,status')
      .eq('customer_id', proposal.customer_id).eq('status', 'active').order('created_at', { ascending: false }),
    supabase.from('proposal_external_identities').select('institution_key,external_proposal_number,source,first_seen_at').eq('proposal_id', id).order('first_seen_at'),
    supabase.from('proposal_submissions').select('status,decision_reason').eq('proposal_id', id).maybeSingle(),
  ])

  const customer = (proposal.customer_snapshot ?? {}) as Record<string, unknown>
  const commercial = (proposal.commercial_snapshot ?? {}) as Record<string, unknown>
  const pendingRequired = (requirements ?? []).filter(r => r.required_snapshot && !['validated', 'waived'].includes(r.status))

  return <section>
    <Link href="/app/propostas" className="text-sm text-slate-400 hover:text-white">← Propostas</Link>
    <div className="mt-4 flex flex-wrap items-start justify-between gap-4">
      <div>
        <div className="text-sm text-emerald-400">Proposta {proposal.id.slice(0, 8)}</div>
        <h1 className="mt-1 text-3xl font-semibold">{String(customer.full_name ?? 'Cliente')}</h1>
        <p className="mt-2 text-sm text-slate-400">Criada em {new Date(proposal.created_at).toLocaleString('pt-BR')}</p>
      </div>
      <div className="text-right"><span className="rounded-full bg-slate-800 px-3 py-1.5 text-sm">{proposalStatusLabel(proposal.status).label}</span><p className="mt-2 max-w-xs text-xs text-slate-400">{proposalStatusLabel(proposal.status).next}</p></div>
    </div>

    {submission && submission.status !== 'validated' && (
      <div className="mt-4 rounded-[14px] border border-line bg-surface px-5 py-3 text-sm text-ink">
        {submission.status === 'pending'
          ? <>Enviada pelo portal do corretor e <strong>aguardando validação</strong>: ainda não está na esteira e não tem comissão. <Link href="/app/propostas/validacao" className="text-brand underline">Validar ou recusar</Link></>
          : <>Recusada na validação do portal: {submission.decision_reason}</>}
      </div>
    )}
    <PipelineCard supabase={supabase} access={access} proposalId={proposal.id} />
    <CommissionCard supabase={supabase} access={access} proposalId={proposal.id} closed={['paid', 'rejected', 'cancelled'].includes(proposal.status)} />

    <div className="mt-6 flex flex-wrap gap-3">
      {['draft','documents_pending'].includes(proposal.status) && <form action={prepareDocuments}>
        <input type="hidden" name="proposal_id" value={proposal.id}/>
        <button className="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-950">Preparar checklist</button>
      </form>}
      {proposal.status === 'ready_for_digitization' && <form action={sendToDigitization}>
        <input type="hidden" name="proposal_id" value={proposal.id}/>
        <button className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Enviar para digitação</button>
      </form>}
    </div>

    <div className="mt-7 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {[
        ['Solicitado', brl(proposal.requested_amount)],
        ['Liberado', brl(proposal.released_amount)],
        ['Parcela', brl(proposal.installment_amount)],
        ['Prazo', proposal.term ? String(proposal.term) : '—'],
      ].map(([label, value]) => <div key={label} className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><div className="text-xs text-slate-500">{label}</div><div className="mt-2 text-lg font-semibold">{value}</div></div>)}
    </div>

    <div className="mt-6 grid gap-6 xl:grid-cols-2">
      <div className="rounded-2xl border border-slate-800 bg-slate-900 p-5">
        <h2 className="font-semibold">Checklist documental</h2>
        <p className="mt-1 text-xs text-slate-500">{pendingRequired.length} obrigatório(s) pendente(s)</p>
        <div className="mt-4 grid gap-2">
          {requirements?.map(r => {
            const compatible = (customerDocuments ?? []).filter(d => d.document_type_id === r.document_type_id)
            return <div key={r.id} className="rounded-lg bg-slate-950 p-3 text-sm">
              <div className="flex items-center justify-between gap-3"><span>{r.label_snapshot}{r.required_snapshot ? ' *' : ''}</span><span className="text-xs text-slate-400">{r.status}</span></div>
              {!['validated','waived'].includes(r.status) && compatible.length > 0 && <form action={attachDocument} className="mt-3 flex gap-2">
                <input type="hidden" name="proposal_id" value={proposal.id}/><input type="hidden" name="requirement_id" value={r.id}/>
                <select name="document_id" className="field min-w-0 flex-1" defaultValue=""><option value="" disabled>Selecionar evidência</option>{compatible.map(d => <option key={d.id} value={d.id}>{d.original_file_name} · v{d.version}</option>)}</select>
                <button className="rounded-lg bg-slate-800 px-3 text-xs">Vincular</button>
              </form>}
              {r.status === 'attached' && atLeast(membership.role,'supervisor') && <form action={validateRequirement} className="mt-2">
                <input type="hidden" name="proposal_id" value={proposal.id}/><input type="hidden" name="requirement_id" value={r.id}/>
                <button className="text-xs font-medium text-emerald-400">Validar evidência</button>
              </form>}
            </div>
          })}
          {!requirements?.length && <p className="text-sm text-slate-500">Checklist ainda não instanciado para esta proposta.</p>}
        </div>
      </div>

      <div className="rounded-2xl border border-slate-800 bg-slate-900 p-5">
        <h2 className="font-semibold">Operação</h2>
        <dl className="mt-4 grid gap-3 text-sm">
          <div><dt className="text-xs text-slate-500">Fila de digitação</dt><dd>{job?.status ?? 'Ainda não enviada'}</dd></div>
          <div><dt className="text-xs text-slate-500">Estado canônico</dt><dd>{operationalCase?.canonical_state ?? '—'}</dd></div>
          <div><dt className="text-xs text-slate-500">Status externo bruto</dt><dd>{operationalCase?.external_status_raw ?? '—'}</dd></div>
        </dl>
      </div>
    </div>

    <div className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Identidades externas</h2>{!externalIds?.length?<p className="mt-3 text-sm text-slate-500">Nenhum número externo reconciliado.</p>:<div className="mt-3 space-y-2">{externalIds.map((x,i)=><div key={`${x.institution_key}-${x.external_proposal_number}-${i}`} className="rounded-lg bg-slate-950 p-3 text-sm"><strong>{x.external_proposal_number}</strong><span className="ml-3 text-slate-400">{x.institution_key}</span>{x.source&&<span className="ml-3 text-slate-500">{x.source}</span>}</div>)}</div>}</div>

    <details className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5">
      <summary className="cursor-pointer text-sm font-medium">Snapshot comercial</summary>
      <pre className="mt-4 overflow-auto text-xs text-slate-400">{JSON.stringify(commercial, null, 2)}</pre>
    </details>
  </section>
}
