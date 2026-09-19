import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { buildLedger,bucketTotals,EVENT_LABEL,formatBRL,type LedgerEvent } from '@/lib/finance/ledger'
import { cmp,fromDecimalString } from '@/lib/commission/money'
import { refreshFinancialReconciliation } from '../../../propostas/[id]/actions'
import { resolveReconciliationCase,reverseFinancialEvent } from '../../actions'

const ERR:Record<string,string>={
 forbidden:'Seu perfil não pode executar esta ação.',invalid_request:'Requisição inválida.',invalid_reversal_amount:'Valor de reversão inválido (use até 2 casas decimais, maior que zero).',
 reversal_reason_required:'Informe o motivo da reversão.',reversal_source_required:'Escolha a fonte da evidência.',reversal_reference_required:'Informe a referência da evidência (documento, extrato, protocolo).',
 reversal_exceeds_original:'A soma das reversões não pode ultrapassar o valor original.',cannot_reverse_a_reversal_or_adjustment:'Uma reversão não pode ser revertida.',event_not_found:'Evento não encontrado.',
 reversal_failed:'Não foi possível registrar a reversão.',resolution_note_required:'Descreva a justificativa (mínimo de 10 caracteres).',resolution_note_too_long:'Justificativa longa demais (máximo 2000).',resolution_failed:'Não foi possível resolver o caso.'
}
const OK:Record<string,string>={reversal:'Reversão registrada como evento compensatório. O evento original não foi alterado.',resolved:'Caso resolvido. Valores permanecem os derivados do ledger.'}
const STATUS:Record<string,string>={open:'Aberto',matched:'Conciliado',divergent:'Divergente',human_required:'Revisão humana',resolved:'Resolvido'}
const SOURCE_LABEL:Record<string,string>={bank_report:'Relatório do banco',partner_report:'Relatório do parceiro',payment_evidence:'Comprovante de pagamento',manual_review:'Revisão manual',proposal_snapshot:'Snapshot da proposta',import:'Importação',system:'Sistema'}

export default async function CasePage({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{erro?:string;ok?:string}>}){
 const {id}=await params
 const sp=await searchParams
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><h1 className="text-3xl font-semibold">Financeiro</h1><p className="mt-3 text-sm text-slate-400">Dados de comissão e conciliação são restritos aos perfis administrador, gerente e supervisor.</p></section>
 const {data:c}=await supabase.from('financial_reconciliation_cases').select('id,proposal_id,component_type,status,resolution_note,resolved_by,resolved_at,updated_at,expected_text:expected_amount::text,reported_text:reported_amount::text,settled_text:settled_amount::text,divergence_text:divergence_amount::text').eq('id',id).maybeSingle()
 if(!c)notFound()
 let q=supabase.from('financial_events').select('id,event_type,component_type,amount_text:amount::text,currency,occurred_at,created_at,source_kind,source_reference,reverses_event_id,metadata').eq('proposal_id',c.proposal_id).order('created_at')
 q=c.component_type===null?q.is('component_type',null):q.eq('component_type',c.component_type)
 const {data:events}=await q
 const ids=(events??[]).map(e=>e.id)
 const {data:links}=ids.length?await supabase.from('financial_evidence_links').select('financial_event_id,evidence_kind,evidence_reference,import_batch_id').in('financial_event_id',ids):{data:[]}
 const ledger=buildLedger((events??[]) as LedgerEvent[])
 let buckets:ReturnType<typeof bucketTotals>|null=null
 let ledgerError=false
 try{buckets=bucketTotals(ledger)}catch{ledgerError=true}
 const differs=(a:string,b:string|null)=>b===null||cmp(fromDecimalString(a),fromDecimalString(b))!==0
 const stale=!!buckets&&(differs(buckets.expected,c.expected_text)||differs(buckets.reported,c.reported_text)||differs(buckets.settled,c.settled_text))
 const evidenceOf=(eid:string)=>(links??[]).filter(l=>l.financial_event_id===eid)
 const resolved=c.status==='resolved'
 return <section>
  <Link href="/app/financeiro" className="text-sm text-slate-400">← Financeiro</Link>
  <h1 className="mt-3 text-3xl font-semibold">Caso de conciliação</h1>
  <p className="mt-2 text-sm text-slate-400">Proposta <Link className="underline" href={`/app/propostas/${c.proposal_id}`}>{c.proposal_id.slice(0,8)}…</Link> · componente {c.component_type??'—'} · atualizado {new Date(c.updated_at).toLocaleString('pt-BR')}</p>
  {sp.erro&&<div role="alert" className="mt-4 rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">{ERR[sp.erro]??'Não foi possível concluir a ação.'}</div>}
  {sp.ok&&OK[sp.ok]&&<div role="status" className="mt-4 rounded-lg border border-emerald-500/40 bg-emerald-500/10 p-3 text-sm text-emerald-200">{OK[sp.ok]}</div>}
  {ledgerError&&<div role="alert" className="mt-4 rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">O ledger desta proposta produz saldo negativo. Isso não deveria ser possível: trate como incidente.</div>}
  <div className="mt-6 grid gap-4 md:grid-cols-5">
   {[['Esperado',c.expected_text],['Reportado',c.reported_text],['Recebido',c.settled_text],['Diferença',c.divergence_text],['Status',STATUS[c.status]??c.status]].map(([l,v])=><div key={l} className="rounded-xl border border-slate-800 bg-slate-900 p-4"><div className="text-xs text-slate-400">{l}</div><div className="mt-2 text-xl font-semibold">{l==='Status'?v:formatBRL(v)}</div></div>)}
  </div>
  {stale&&buckets&&<div role="status" className="mt-3 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-200">O ledger indica esperado {formatBRL(buckets.expected)}, reportado {formatBRL(buckets.reported)}, recebido {formatBRL(buckets.settled)} — diferente do caso salvo. Recalcule a conciliação.</div>}
  <form action={refreshFinancialReconciliation} className="mt-3"><input type="hidden" name="proposal_id" value={c.proposal_id}/><input type="hidden" name="component_type" value={c.component_type??''}/><button className="rounded-lg border border-slate-700 px-3 py-2 text-sm">Recalcular a partir do ledger</button></form>

  <h2 className="mt-8 text-xl font-semibold">Ledger e reversões</h2>
  <p className="mt-1 text-xs text-slate-500">Eventos são append-only. Uma reversão nunca altera o original: cria um evento compensatório e reduz o saldo líquido.</p>
  {!ledger.entries.length?<p className="mt-4 text-sm text-slate-400">Nenhum evento financeiro para este componente.</p>:<div className="mt-4 space-y-4">
   {ledger.entries.map(e=>{const ev=evidenceOf(e.original.id);const canReverse=Number(e.remainingReversible)>0
    return <article key={e.original.id} className="rounded-xl border border-slate-800 bg-slate-900 p-4">
     <header className="flex flex-wrap items-baseline justify-between gap-2"><h3 className="font-semibold">{EVENT_LABEL[e.original.event_type]??e.original.event_type}</h3><span className="text-sm text-slate-400">{new Date(e.original.occurred_at).toLocaleDateString('pt-BR')} · {SOURCE_LABEL[e.original.source_kind]??e.original.source_kind}{e.original.source_reference?` · ref. ${e.original.source_reference}`:''}</span></header>
     <div className="mt-2 text-sm">ORIGINAL <strong>{formatBRL(e.original.amount_text)}</strong></div>
     {e.reversals.length>0&&<ul className="mt-2 space-y-1 border-l-2 border-amber-500/50 pl-3 text-sm">{e.reversals.map(r=><li key={r.id}>↳ REVERSÃO <strong>−{formatBRL(r.amount_text)}</strong> <span className="text-slate-400">· {new Date(r.created_at).toLocaleString('pt-BR')} · {SOURCE_LABEL[r.source_kind]??r.source_kind} · ref. {r.source_reference??'—'}{(r.metadata as {reason?:string}|null)?.reason?` · motivo: ${(r.metadata as {reason?:string}).reason}`:''}</span></li>)}</ul>}
     <div className="mt-2 text-sm">SALDO LÍQUIDO <strong>{formatBRL(e.net)}</strong></div>
     {ev.length>0&&<div className="mt-2 text-xs text-slate-500">Evidência: {ev.map(l=>`${l.evidence_kind}${l.evidence_reference?` (${l.evidence_reference})`:''}${l.import_batch_id?` · lote ${l.import_batch_id.slice(0,8)}…`:''}`).join(' · ')}</div>}
     {canReverse&&!resolved&&<details className="mt-3"><summary className="cursor-pointer text-sm text-amber-300">Registrar reversão (parcial ou total)</summary>
      <form action={reverseFinancialEvent} className="mt-3 grid gap-2 md:grid-cols-2">
       <input type="hidden" name="case_id" value={c.id}/><input type="hidden" name="event_id" value={e.original.id}/>
       <label className="text-xs text-slate-400">Valor (máx. {formatBRL(e.remainingReversible)})<input name="amount" required inputMode="decimal" placeholder="0,00" className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm"/></label>
       <label className="text-xs text-slate-400">Fonte da evidência<select name="source_kind" required className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm"><option value="bank_report">Relatório do banco</option><option value="partner_report">Relatório do parceiro</option><option value="payment_evidence">Comprovante de pagamento</option><option value="manual_review">Revisão manual</option></select></label>
       <label className="text-xs text-slate-400 md:col-span-2">Referência da evidência<input name="source_reference" required maxLength={200} className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm"/></label>
       <label className="text-xs text-slate-400 md:col-span-2">Motivo<input name="reason" required maxLength={300} className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm"/></label>
       <button className="rounded-lg bg-amber-400 px-3 py-2 text-sm font-semibold text-slate-950 md:col-span-2">Registrar reversão</button>
      </form></details>}
    </article>})}
  </div>}
  {(ledger.orphanReversals.length>0||ledger.ungoverned.length>0)&&<div role="alert" className="mt-4 rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-200">Eventos fora do modelo governado: {ledger.orphanReversals.length} reversão(ões) sem original e {ledger.ungoverned.length} evento(s) de tipo não governado. Não entram nos saldos.</div>}

  <h2 className="mt-8 text-xl font-semibold">Resolução humana</h2>
  {resolved?<div className="mt-3 rounded-xl border border-slate-800 bg-slate-900 p-4 text-sm"><div>Resolvido em {c.resolved_at?new Date(c.resolved_at).toLocaleString('pt-BR'):'—'} pelo usuário {c.resolved_by?c.resolved_by.slice(0,8)+'…':'—'} (registrado pelo servidor).</div><p className="mt-2 text-slate-300">{c.resolution_note}</p></div>
  :<form action={resolveReconciliationCase} className="mt-3 rounded-xl border border-slate-800 bg-slate-900 p-4">
   <input type="hidden" name="case_id" value={c.id}/>
   <p className="text-xs text-slate-500">Resolver não altera esperado, reportado nem recebido: esses valores são derivados do ledger. Use reversões acima para corrigir fatos; aqui registre a justificativa da decisão.</p>
   <label className="mt-3 block text-xs text-slate-400">Justificativa<textarea name="resolution_note" required minLength={10} maxLength={2000} rows={3} className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm"/></label>
   <button className="mt-3 rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Resolver caso</button>
  </form>}
 </section>
}
