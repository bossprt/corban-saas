import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { applyApprovedImportMatch, decideImportCandidate, publishApprovedImportFinancialFact, confirmPaidFromImport } from './actions'

export default async function ImportBatchPage({params}:{params:Promise<{id:string}>}){
 const {id}=await params
 const {supabase,membership}=await requireAppContext()
 const {data:batch}=await supabase.from('import_batches').select('id,source_id,original_filename,status,row_count,received_at,parser_key,parser_version,content_sha256').eq('id',id).maybeSingle()
 if(!batch)notFound()
 const {data:source}=await supabase.from('import_sources').select('financial_semantic').eq('id',batch.source_id).maybeSingle()
 const {data:rows}=await supabase.from('import_normalized_rows').select('id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,commission_upfront,commission_deferred').in('raw_row_id',(await supabase.from('import_raw_rows').select('id').eq('batch_id',id)).data?.map(r=>r.id)??[]).limit(200)
 const rowIds=rows?.map(r=>r.id)??[]
 const {data:candidates}=rowIds.length?await supabase.from('import_match_candidates').select('id,normalized_row_id,match_strength,status,proposal_id,product_table_id,channel_id').in('normalized_row_id',rowIds):{data:[]}
 const candidateIds=candidates?.map(c=>c.id)??[]
 const {data:decisions}=candidateIds.length?await supabase.from('import_decisions').select('id,candidate_id,decision,decided_at').in('candidate_id',candidateIds).order('decided_at',{ascending:false}):{data:[]}
 const decisionIds=decisions?.map(d=>d.id)??[]
 const {data:applied}=decisionIds.length?await supabase.from('import_applied_decisions').select('decision_id,applied_at').in('decision_id',decisionIds):{data:[]}
 const byRow=new Map((candidates??[]).map(c=>[c.normalized_row_id,c]))
 type ReviewDecision={id:string;candidate_id:string;decision:string;decided_at:string}
 const latestDecision=new Map<string,ReviewDecision>()
 for(const d of decisions??[])if(!latestDecision.has(d.candidate_id))latestDecision.set(d.candidate_id,d as ReviewDecision)
 const appliedSet=new Set((applied??[]).map(a=>a.decision_id))
 const canReview=['admin','manager','supervisor'].includes(membership.role)
 const financialSemantic=source?.financial_semantic??'unclassified'
 const {data:financialLinks}=decisionIds.length?await supabase.from('financial_evidence_links').select('import_decision_id').in('import_decision_id',decisionIds):{data:[]}
 const financiallyPublished=new Set((financialLinks??[]).map(x=>x.import_decision_id))
 return <section>
  <Link href="/app/importacoes" className="text-sm text-slate-400">← Importações</Link>
  <h1 className="mt-3 text-3xl font-semibold">{batch.original_filename}</h1>
  <p className="mt-2 text-sm text-slate-400">Status {batch.status} · parser {batch.parser_key??'—'} {batch.parser_version??''} · SHA-256 {batch.content_sha256.slice(0,12)}…</p><div className="mt-3 inline-flex rounded-lg border border-slate-700 px-3 py-2 text-xs text-slate-300">Semântica financeira: {financialSemantic}{financialSemantic==='commercial_offer'?' · não publica recebimento':''}</div>
  <div className="mt-6 overflow-x-auto rounded-xl border border-slate-800">
   <table className="min-w-full text-left text-sm"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-3">Banco</th><th className="p-3">Proposta/Tabela</th><th className="p-3">Operação</th><th className="p-3">Prazo</th><th className="p-3">Comissão</th><th className="p-3">Matching</th></tr></thead>
   <tbody>{!rows?.length?<tr><td colSpan={6} className="p-5 text-slate-400">Nenhuma linha normalizada.</td></tr>:rows.map(r=>{const m=byRow.get(r.id);return <tr key={r.id} className="border-t border-slate-800"><td className="p-3">{r.bank_key??'—'}</td><td className="p-3">{r.external_proposal_number??r.external_table_code??'—'}<div className="text-xs text-slate-500">{r.external_table_name}</div></td><td className="p-3">{r.operation_type??r.record_kind}</td><td className="p-3">{r.term??'—'}</td><td className="p-3">{r.commission_upfront??'—'}{r.commission_deferred&&<span className="text-slate-500"> + diferido {r.commission_deferred}</span>}</td><td className="p-3">{m?<><strong>{m.match_strength}</strong><div className="text-xs text-slate-500">{m.status}</div>{canReview&&!latestDecision.get(m.id)&&m.status==='suggested'&&<form action={decideImportCandidate} className="mt-2 flex flex-wrap gap-1"><input type="hidden" name="batch_id" value={id}/><input type="hidden" name="normalized_row_id" value={r.id}/><input type="hidden" name="candidate_id" value={m.id}/>{m.match_strength!=='ambiguous'&&<button name="decision" value="approve" className="rounded border border-slate-700 px-2 py-1 text-xs">Aprovar</button>}<button name="decision" value="reject" className="rounded border border-slate-700 px-2 py-1 text-xs">Rejeitar</button><button name="decision" value="human_required" className="rounded border border-slate-700 px-2 py-1 text-xs">Revisar</button></form>}{latestDecision.get(m.id)?.decision==='approve'&&!appliedSet.has(latestDecision.get(m.id)!.id)&&canReview&&<form action={applyApprovedImportMatch} className="mt-2"><input type="hidden" name="batch_id" value={id}/><input type="hidden" name="decision_id" value={latestDecision.get(m.id)!.id}/><button className="rounded bg-emerald-500 px-2 py-1 text-xs font-medium text-slate-950">Aplicar vínculo aprovado</button></form>}{latestDecision.get(m.id)?.decision==='approve'&&appliedSet.has(latestDecision.get(m.id)!.id)&&financialSemantic==='production_report'&&r.record_kind==='status'&&canReview&&<form action={confirmPaidFromImport} className="mt-2"><input type="hidden" name="batch_id" value={id}/><input type="hidden" name="decision_id" value={latestDecision.get(m.id)!.id}/><button className="rounded bg-sky-400 px-2 py-1 text-xs font-medium text-slate-950">Confirmar PAID por evidência</button></form>}{latestDecision.get(m.id)?.decision==='approve'&&appliedSet.has(latestDecision.get(m.id)!.id)&&!['commercial_offer','production_report'].includes(financialSemantic)&&!financiallyPublished.has(latestDecision.get(m.id)!.id)&&canReview&&<form action={publishApprovedImportFinancialFact} className="mt-2"><input type="hidden" name="batch_id" value={id}/><input type="hidden" name="decision_id" value={latestDecision.get(m.id)!.id}/><button className="rounded bg-amber-400 px-2 py-1 text-xs font-medium text-slate-950">Publicar fato financeiro comprovado</button></form>}{latestDecision.get(m.id)&&<div className="mt-1 text-xs text-slate-500">decisão: {latestDecision.get(m.id)!.decision}{appliedSet.has(latestDecision.get(m.id)!.id)?' · aplicada':''}{financiallyPublished.has(latestDecision.get(m.id)!.id)?' · financeiro publicado':''}</div>}</>:<span className="text-slate-500">não avaliado</span>}</td></tr>})}</tbody></table>
  </div>
  <p className="mt-4 text-xs text-slate-500">Matching ambíguo permanece para revisão humana. Esta tela não publica tabela, proposta ou valor financeiro.</p>
 </section>
}
