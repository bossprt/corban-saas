import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'

export default async function ImportBatchPage({params}:{params:Promise<{id:string}>}){
 const {id}=await params
 const {supabase}=await requireAppContext()
 const {data:batch}=await supabase.from('import_batches').select('id,original_filename,status,row_count,received_at,parser_key,parser_version,content_sha256').eq('id',id).maybeSingle()
 if(!batch)notFound()
 const {data:rows}=await supabase.from('import_normalized_rows').select('id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,commission_upfront,commission_deferred').in('raw_row_id',(await supabase.from('import_raw_rows').select('id').eq('batch_id',id)).data?.map(r=>r.id)??[]).limit(200)
 const rowIds=rows?.map(r=>r.id)??[]
 const {data:candidates}=rowIds.length?await supabase.from('import_match_candidates').select('id,normalized_row_id,match_strength,status,proposal_id,product_table_id,channel_id').in('normalized_row_id',rowIds):{data:[]}
 const byRow=new Map((candidates??[]).map(c=>[c.normalized_row_id,c]))
 return <section>
  <Link href="/app/importacoes" className="text-sm text-slate-400">← Importações</Link>
  <h1 className="mt-3 text-3xl font-semibold">{batch.original_filename}</h1>
  <p className="mt-2 text-sm text-slate-400">Status {batch.status} · parser {batch.parser_key??'—'} {batch.parser_version??''} · SHA-256 {batch.content_sha256.slice(0,12)}…</p>
  <div className="mt-6 overflow-x-auto rounded-xl border border-slate-800">
   <table className="min-w-full text-left text-sm"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-3">Banco</th><th className="p-3">Proposta/Tabela</th><th className="p-3">Operação</th><th className="p-3">Prazo</th><th className="p-3">Comissão</th><th className="p-3">Matching</th></tr></thead>
   <tbody>{!rows?.length?<tr><td colSpan={6} className="p-5 text-slate-400">Nenhuma linha normalizada.</td></tr>:rows.map(r=>{const m=byRow.get(r.id);return <tr key={r.id} className="border-t border-slate-800"><td className="p-3">{r.bank_key??'—'}</td><td className="p-3">{r.external_proposal_number??r.external_table_code??'—'}<div className="text-xs text-slate-500">{r.external_table_name}</div></td><td className="p-3">{r.operation_type??r.record_kind}</td><td className="p-3">{r.term??'—'}</td><td className="p-3">{r.commission_upfront??'—'}{r.commission_deferred&&<span className="text-slate-500"> + diferido {r.commission_deferred}</span>}</td><td className="p-3">{m?<><strong>{m.match_strength}</strong><div className="text-xs text-slate-500">{m.status}</div></>:<span className="text-slate-500">não avaliado</span>}</td></tr>})}</tbody></table>
  </div>
  <p className="mt-4 text-xs text-slate-500">Matching ambíguo permanece para revisão humana. Esta tela não publica tabela, proposta ou valor financeiro.</p>
 </section>
}
