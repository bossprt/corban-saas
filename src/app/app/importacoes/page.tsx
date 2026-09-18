import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'

export default async function ImportsPage() {
 const { supabase }=await requireAppContext()
 const {data,error}=await supabase.from('import_batches').select('id,original_filename,status,row_count,received_at').order('received_at',{ascending:false}).limit(50)
 return <section><h1 className="text-3xl font-semibold">Importações</h1>
 <p className="mt-2 text-sm text-slate-400">Lineage de arquivos, parsing, normalização, matching e revisão antes de qualquer alteração operacional ou financeira.</p>
 <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5">
 {error?<p className="text-amber-300">Motor de importação preparado no código e aguardando ativação do schema.</p>:
 !data?.length?<p className="text-slate-400">Nenhum lote importado.</p>:
 <div className="space-y-2">{data.map(b=><div key={b.id} className="rounded-lg border border-slate-800 p-3 text-sm"><Link href={`/app/importacoes/${b.id}`} className="font-semibold hover:underline">{b.original_filename}</Link><span className="ml-3 text-slate-400">{b.status}</span><span className="ml-3 text-slate-500">{b.row_count??'—'} linhas</span></div>)}</div>}
 </div></section>
}
