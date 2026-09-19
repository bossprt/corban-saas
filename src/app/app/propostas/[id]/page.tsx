import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { attachDocument, prepareDocuments, sendToDigitization, validateRequirement, publishExpectedCommission } from './actions'
import { atLeast, canViewCommission } from '@/lib/rbac'

function brl(value: number | string | null) {
  return value === null ? '—' : Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

export default async function ProposalDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const { supabase, membership } = await requireAppContext()

  const { data: proposal } = await supabase.from('proposals_v2')
    .select('id,status,customer_id,simulation_id,requested_amount,released_amount,installment_amount,term,rate,expected_commission_amount,customer_snapshot,commercial_snapshot,created_at')
    .eq('id', id).maybeSingle()

  if (!proposal) notFound()

  const [{ data: requirements }, { data: job }, { data: operationalCase }, { data: customerDocuments }, { data: externalIds }, { data: commercialRouteRaw }, { data: financialEventsRaw }] = await Promise.all([
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
    supabase.from('proposal_external_identities').select('institution_key,external_proposal_number,source,channel_id,first_seen_at').eq('proposal_id', id).order('first_seen_at'),
    canViewCommission(membership.role)
      ? supabase.rpc('get_commercial_route',{p_proposal_id:id}).maybeSingle().then(async r => r.error
        // RPC absent (migration not applied yet) or refused: operational columns only, valid before and after the migration
        ? supabase.from('proposal_commercial_snapshots').select('channel_id,producer_entity_id,payer_entity_id,created_at').eq('proposal_id', id).maybeSingle()
        : r)
      : supabase.from('proposal_commercial_snapshots').select('channel_id,producer_entity_id,payer_entity_id,created_at').eq('proposal_id', id).maybeSingle(),
    supabase.from('financial_events').select('id,event_type,component_type,amount,currency,created_at').eq('proposal_id',id).order('created_at',{ascending:false}),
  ])

  type CommercialRoute = { channel_id: string | null; producer_entity_id: string | null; payer_entity_id: string | null; commission_rule_version_id?: string | null; split_rule_version_id?: string | null; snapshot?: unknown } | null
  const commercialRoute = commercialRouteRaw as CommercialRoute
  // Financial facts expose commission economics: only supervisor+ roles see them (server-side gate on top of RLS).
  const financialEvents = canViewCommission(membership.role) ? financialEventsRaw : []
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
      <span className="rounded-full bg-slate-800 px-3 py-1.5 text-sm">{proposal.status}</span>
    </div>

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

    <div className="mt-6 grid gap-6 xl:grid-cols-2"><div className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Identidades externas</h2>{!externalIds?.length?<p className="mt-3 text-sm text-slate-500">Nenhum número externo reconciliado.</p>:<div className="mt-3 space-y-2">{externalIds.map((x,i)=><div key={`${x.institution_key}-${x.external_proposal_number}-${i}`} className="rounded-lg bg-slate-950 p-3 text-sm"><strong>{x.external_proposal_number}</strong><span className="ml-3 text-slate-400">{x.institution_key}</span>{x.source&&<span className="ml-3 text-slate-500">{x.source}</span>}</div>)}</div>}</div><div className="rounded-2xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Rota comercial congelada</h2>{!commercialRoute?<p className="mt-3 text-sm text-slate-500">Ainda sem snapshot de canal/rede.</p>:<dl className="mt-3 grid gap-2 text-sm"><div><dt className="text-xs text-slate-500">Canal</dt><dd>{commercialRoute.channel_id}</dd></div><div><dt className="text-xs text-slate-500">Produtor</dt><dd>{commercialRoute.producer_entity_id??'—'}</dd></div><div><dt className="text-xs text-slate-500">Pagador</dt><dd>{commercialRoute.payer_entity_id??'—'}</dd></div></dl>}</div></div>

    <div className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3"><div><h2 className="font-semibold">Verdade financeira</h2><p className="mt-1 text-xs text-slate-500">Comissão esperada não significa comissão recebida.</p></div>
      {commercialRoute && atLeast(membership.role,'supervisor') && <div className="flex flex-wrap gap-2"><form action={publishExpectedCommission}><input type="hidden" name="proposal_id" value={proposal.id}/><button className="rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Publicar comissão esperada</button></form></div>}</div>
      {!financialEvents?.length?<p className="mt-4 text-sm text-slate-500">Nenhum fato financeiro publicado para esta proposta.</p>:<div className="mt-4 space-y-2">{financialEvents.map(e=><div key={e.id} className="flex justify-between rounded-lg bg-slate-950 p-3 text-sm"><span>{e.event_type} · {e.component_type??'—'}</span><strong>{e.currency} {Number(e.amount).toLocaleString('pt-BR',{minimumFractionDigits:2})}</strong></div>)}</div>}
    </div>

    <details className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5">
      <summary className="cursor-pointer text-sm font-medium">Snapshot comercial</summary>
      <pre className="mt-4 overflow-auto text-xs text-slate-400">{JSON.stringify(commercial, null, 2)}</pre>
    </details>
  </section>
}
