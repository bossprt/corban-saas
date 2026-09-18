import { requireAppContext } from '@/lib/appContext'

export default async function FinancePage(){
 const {supabase}=await requireAppContext()
 const {count:proposals}=await supabase.from('proposals_v2').select('*',{count:'exact',head:true})
 const {count:snapshots}=await supabase.from('proposal_commercial_snapshots').select('*',{count:'exact',head:true})
 const {count:appliedMatches}=await supabase.from('import_applied_decisions').select('*',{count:'exact',head:true})
 return <section>
  <h1 className="text-3xl font-semibold">Financeiro</h1>
  <p className="mt-2 text-sm text-slate-400">Preparação para conciliação de comissão esperada, reportada e efetivamente recebida. Nenhum matching isolado é tratado como pagamento.</p>
  <div className="mt-6 grid gap-4 md:grid-cols-3">
   {[['Propostas',proposals??0],['Rotas congeladas',snapshots??0],['Matches aplicados',appliedMatches??0]].map(([l,v])=><div key={String(l)} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{l}</div><div className="mt-2 text-3xl font-semibold">{v}</div></div>)}
  </div>
  <div className="mt-6 rounded-xl border border-amber-900/60 bg-slate-900 p-5">
   <h2 className="font-semibold">Financial Truth Gate</h2>
   <p className="mt-2 text-sm text-slate-400">Receita, repasse, bônus e recebimento permanecerão separados e auditáveis. O ledger ainda não está ativo; esta tela não calcula nem publica valores financeiros.</p>
  </div>
 </section>
}
