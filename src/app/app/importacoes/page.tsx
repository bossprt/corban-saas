import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'

export default async function ImportsPage(){
 const {supabase}=await requireAppContext()
 const {data,error}=await supabase.from('import_batches').select('id,original_filename,status,row_count,received_at,parser_key,parser_version,source_id').order('received_at',{ascending:false}).limit(50)
 const batchIds=data?.map(b=>b.id)??[]
 const {data:raw}=batchIds.length?await supabase.from('import_raw_rows').select('id,batch_id').in('batch_id',batchIds):{data:[]}
 const rawIds=raw?.map(r=>r.id)??[]
 const {data:normalized}=rawIds.length?await supabase.from('import_normalized_rows').select('id,raw_row_id').in('raw_row_id',rawIds):{data:[]}
 const normalizedIds=normalized?.map(r=>r.id)??[]
 const {data:candidates}=normalizedIds.length?await supabase.from('import_match_candidates').select('normalized_row_id,match_strength,status').in('normalized_row_id',normalizedIds):{data:[]}
 const rawBatch=new Map((raw??[]).map(r=>[r.id,r.batch_id]))
 const normalizedBatch=new Map((normalized??[]).map(r=>[r.id,rawBatch.get(r.raw_row_id)]))
 const stats=new Map<string,{normalized:number;matched:number;human:number}>()
 for(const b of data??[])stats.set(b.id,{normalized:0,matched:0,human:0})
 for(const n of normalized??[]){const b=rawBatch.get(n.raw_row_id);if(b)stats.get(b)!.normalized++}
 for(const m of candidates??[]){const b=normalizedBatch.get(m.normalized_row_id);if(!b)continue;const s=stats.get(b)!;if(['exact','strong'].includes(m.match_strength))s.matched++;if(m.status==='human_required'||m.match_strength==='ambiguous')s.human++}
 return <section><h1 className="text-3xl font-semibold">Importações</h1>
 <p className="mt-2 text-sm text-slate-400">Lineage de arquivos, parsing, normalização, matching e revisão antes de qualquer alteração operacional ou financeira.</p>
 <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5">
 {error?<p className="text-amber-300">Não foi possível consultar os lotes.</p>:!data?.length?<p className="text-slate-400">Nenhum lote importado.</p>:
 <div className="space-y-2">{data.map(b=>{const s=stats.get(b.id)!;return <div key={b.id} className="rounded-lg border border-slate-800 p-3 text-sm">
  <div className="flex flex-wrap items-center justify-between gap-2"><Link href={`/app/importacoes/${b.id}`} className="font-semibold hover:underline">{b.original_filename}</Link><span className="text-slate-400">{b.status}</span></div>
  <div className="mt-2 flex flex-wrap gap-4 text-xs text-slate-500"><span>{b.row_count??'—'} linhas fonte</span><span>{s.normalized} normalizadas</span><span>{s.matched} matches fortes</span><span>{s.human} revisão humana</span><span>{b.parser_key??'parser pendente'} {b.parser_version??''}</span></div>
 </div>})}</div>}
 </div></section>
}
