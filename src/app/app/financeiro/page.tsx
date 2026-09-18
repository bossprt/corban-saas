import { requireAppContext } from '@/lib/appContext'

export default async function FinancePage(){
 const {supabase}=await requireAppContext()
 const {count:events}=await supabase.from('financial_events').select('*',{count:'exact',head:true})
 const {count:openCases}=await supabase.from('financial_reconciliation_cases').select('*',{count:'exact',head:true}).eq('status','open')
 const {count:divergent}=await supabase.from('financial_reconciliation_cases').select('*',{count:'exact',head:true}).eq('status','divergent')
 return <section>
  <h1 className="text-3xl font-semibold">Financeiro</h1>
  <p className="mt-2 text-sm text-slate-400">Preparação para conciliação de comissão esperada, reportada e efetivamente recebida. Nenhum matching isolado é tratado como pagamento.</p>
  <div className="mt-6 grid gap-4 md:grid-cols-3">
   {[['Eventos financeiros',events??0],['Conciliações abertas',openCases??0],['Divergências',divergent??0]].map(([l,v])=><div key={String(l)} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{l}</div><div className="mt-2 text-3xl font-semibold">{v}</div></div>)}
  </div>
  <div className="mt-6 rounded-xl border border-amber-900/60 bg-slate-900 p-5">
   <h2 className="font-semibold">Financial Truth Gate</h2>
   <p className="mt-2 text-sm text-slate-400">Receita, repasse, bônus e recebimento permanecerão separados e auditáveis. O ledger append-only está ativo. Publicação de fatos financeiros continua condicionada a evidência determinística ou revisão autorizada.</p>
  </div>
 </section>
}
