import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'

export default async function FinancePage(){
 const {supabase,membership}=await requireAppContext()
 if(!['admin','manager','supervisor'].includes(membership.role))return <section><h1 className="text-3xl font-semibold">Financeiro</h1><p className="mt-3 text-sm text-slate-400">Dados de comissão e conciliação são restritos aos perfis administrador, gerente e supervisor.</p></section>
 const {count:events}=await supabase.from('financial_events').select('*',{count:'exact',head:true})
 const {count:openCases}=await supabase.from('financial_reconciliation_cases').select('*',{count:'exact',head:true}).eq('status','open')
 const {count:divergent}=await supabase.from('financial_reconciliation_cases').select('*',{count:'exact',head:true}).eq('status','divergent')
 const eventCount=events??0
 const openCount=openCases??0
 const divergentCount=divergent??0
 const {data:cases}=await supabase.from('financial_reconciliation_cases').select('id,proposal_id,component_type,expected_amount,reported_amount,settled_amount,divergence_amount,status,updated_at').order('updated_at',{ascending:false}).limit(30)
 return <section>
  <h1 className="text-3xl font-semibold">Financeiro</h1>
  <p className="mt-2 text-sm text-slate-400">Preparação para conciliação de comissão esperada, reportada e efetivamente recebida. Nenhum matching isolado é tratado como pagamento.</p>
  <div className="mt-6 grid gap-4 md:grid-cols-3">
   {[['Eventos financeiros',eventCount],['Conciliações abertas',openCount],['Divergências',divergentCount]].map(([l,v])=><div key={String(l)} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{l}</div><div className="mt-2 text-3xl font-semibold">{v}</div></div>)}
  </div>
  <div className="mt-6 overflow-x-auto rounded-xl border border-slate-800"><table className="min-w-full text-left text-sm"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-3">Proposta</th><th className="p-3">Componente</th><th className="p-3">Esperado</th><th className="p-3">Reportado</th><th className="p-3">Recebido</th><th className="p-3">Divergência</th><th className="p-3">Status</th></tr></thead><tbody>{!cases?.length?<tr><td colSpan={7} className="p-5 text-slate-500">Nenhuma conciliação financeira criada.</td></tr>:cases.map(x=><tr key={x.id} className="border-t border-slate-800"><td className="p-3">{x.proposal_id?<Link className="hover:underline" href={`/app/propostas/${x.proposal_id}`}>{x.proposal_id.slice(0,8)}</Link>:'—'}</td><td className="p-3">{x.component_type??'—'}</td><td className="p-3">{Number(x.expected_amount??0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'})}</td><td className="p-3">{Number(x.reported_amount??0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'})}</td><td className="p-3">{Number(x.settled_amount??0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'})}</td><td className="p-3">{Number(x.divergence_amount??0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'})}</td><td className="p-3">{x.status}</td></tr>)}</tbody></table></div>
  <div className="mt-6 rounded-xl border border-amber-900/60 bg-slate-900 p-5">
   <h2 className="font-semibold">Financial Truth Gate</h2>
   <p className="mt-2 text-sm text-slate-400">Receita, repasse, bônus e recebimento permanecerão separados e auditáveis. O ledger append-only está ativo. Publicação de fatos financeiros continua condicionada a evidência determinística ou revisão autorizada.</p>
  </div>
 </section>
}
