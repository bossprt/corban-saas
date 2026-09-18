import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { createImportSource, ingestImportFile } from './actions'

export default async function ImportsPage(){
 const {supabase,membership}=await requireAppContext()
 const canManage=['admin','manager'].includes(membership.role)
 const {data:sources}=await supabase.from('import_sources').select('id,name,source_kind,financial_semantic,is_active').order('name')
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
 {canManage&&<details className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5"><summary className="cursor-pointer font-semibold">Cadastrar fonte de importação</summary><form action={createImportSource} className="mt-4 grid gap-3 md:grid-cols-2"><input name="name" required placeholder="Ex.: Extrato de comissão Daycoval" className="rounded-lg border border-slate-700 bg-slate-950 p-2"/><select name="source_kind" className="rounded-lg border border-slate-700 bg-slate-950 p-2"><option value="bank">Banco</option><option value="correspondent">Correspondente</option><option value="promotora">Promotora</option><option value="partner">Parceiro</option><option value="legacy_system">Sistema legado</option><option value="manual">Manual</option><option value="other">Outro</option></select><select name="financial_semantic" className="rounded-lg border border-slate-700 bg-slate-950 p-2"><option value="commercial_offer">Oferta comercial — não prova comissão/pagamento</option><option value="production_report">Relatório de produção</option><option value="commission_statement">Extrato de comissão reportada</option><option value="payment_statement">Comprovante/extrato de pagamento recebido</option><option value="network_payment_statement">Pagamento da rede</option></select><button className="rounded-lg bg-emerald-500 px-4 py-2 font-semibold text-slate-950">Cadastrar fonte</button></form></details>}
 {sources?.length?<details className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5"><summary className="cursor-pointer font-semibold">Importar arquivo</summary><form action={ingestImportFile} className="mt-4 grid gap-3 md:grid-cols-2"><select name="source_id" required className="rounded-lg border border-slate-700 bg-slate-950 p-2">{sources.filter(s=>s.is_active).map(s=><option key={s.id} value={s.id}>{s.name} · {s.financial_semantic}</option>)}</select><select name="source_key" required className="rounded-lg border border-slate-700 bg-slate-950 p-2"><option value="daycoval">Daycoval</option><option value="efetiva_mais">Efetiva Mais</option><option value="bevicred">Bevicred</option><option value="commission_statement">Extrato de comissão (CSV governado)</option><option value="payment_statement">Extrato de pagamento recebido (CSV governado)</option><option value="network_payment_statement">Pagamento da rede (CSV governado)</option></select><input type="file" name="file" required accept=".csv,.xls,.xlsx" className="rounded-lg border border-slate-700 bg-slate-950 p-2"/><button className="rounded-lg bg-emerald-500 px-4 py-2 font-semibold text-slate-950">Validar e importar</button><p className="md:col-span-2 text-xs text-slate-500">CSV, XLS em formato HTML e XLSX nativo são processados no servidor. A semântica da fonte deve corresponder ao adapter escolhido.</p></form></details>:null}
 <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Fontes governadas</h2><div className="mt-3 flex flex-wrap gap-2">{!sources?.length?<span className="text-sm text-slate-500">Nenhuma fonte cadastrada.</span>:sources.map(s=><span key={s.id} className="rounded-lg border border-slate-700 px-3 py-2 text-xs">{s.name} · {s.financial_semantic}</span>)}</div></div>
 <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5">
 {error?<p className="text-amber-300">Não foi possível consultar os lotes.</p>:!data?.length?<p className="text-slate-400">Nenhum lote importado.</p>:
 <div className="space-y-2">{data.map(b=>{const s=stats.get(b.id)!;return <div key={b.id} className="rounded-lg border border-slate-800 p-3 text-sm">
  <div className="flex flex-wrap items-center justify-between gap-2"><Link href={`/app/importacoes/${b.id}`} className="font-semibold hover:underline">{b.original_filename}</Link><span className="text-slate-400">{b.status}</span></div>
  <div className="mt-2 flex flex-wrap gap-4 text-xs text-slate-500"><span>{b.row_count??'—'} linhas fonte</span><span>{s.normalized} normalizadas</span><span>{s.matched} matches fortes</span><span>{s.human} revisão humana</span><span>{b.parser_key??'parser pendente'} {b.parser_version??''}</span></div>
 </div>})}</div>}
 </div></section>
}
