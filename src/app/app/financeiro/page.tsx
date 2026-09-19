import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { canViewCommission } from '@/lib/rbac'
import { formatBRL } from '@/lib/finance/ledger'
import { add,fromDecimalString,toDecimalString } from '@/lib/commission/money'

const STATUS:Record<string,string>={open:'Aberto',matched:'Conciliado',divergent:'Divergente',human_required:'Revisão humana',resolved:'Resolvido'}
const FILTERS=['all','open','divergent','human_required','matched','resolved'] as const

export default async function FinancePage({searchParams}:{searchParams:Promise<{status?:string}>}){
 const {supabase,membership}=await requireAppContext()
 if(!canViewCommission(membership.role))return <section><h1 className="text-3xl font-semibold">Financeiro</h1><p className="mt-3 text-sm text-slate-400">Dados de comissão e conciliação são restritos aos perfis administrador, gerente e supervisor.</p></section>
 const sp=await searchParams
 const filter=(FILTERS as readonly string[]).includes(sp.status??'')?sp.status!:'all'
 const {count:events}=await supabase.from('financial_events').select('*',{count:'exact',head:true})
 const {count:reversals}=await supabase.from('financial_events').select('*',{count:'exact',head:true}).eq('event_type','reversal')
 let q=supabase.from('financial_reconciliation_cases').select('id,proposal_id,component_type,status,updated_at,expected_text:expected_amount::text,reported_text:reported_amount::text,settled_text:settled_amount::text,divergence_text:divergence_amount::text').order('updated_at',{ascending:false}).limit(100)
 if(filter!=='all')q=q.eq('status',filter)
 const {data:cases,error}=await q
 const zero=fromDecimalString('0')
 const sum=(k:'expected_text'|'reported_text'|'settled_text')=>toDecimalString((cases??[]).reduce((s,c)=>add(s,fromDecimalString(c[k]??'0')),zero),2)
 const counts=new Map<string,number>()
 for(const c of cases??[])counts.set(c.status,(counts.get(c.status)??0)+1)
 return <section>
  <h1 className="text-3xl font-semibold">Financeiro</h1>
  <p className="mt-2 text-sm text-slate-400">Comissão esperada, reportada e recebida são fatos distintos. Aprovação/produção operacional não significa comissão recebida, e nenhum matching isolado é tratado como pagamento.</p>
  <div className="mt-6 grid gap-4 md:grid-cols-4">
   {[['Esperado (casos listados)',formatBRL(sum('expected_text'))],['Reportado',formatBRL(sum('reported_text'))],['Recebido',formatBRL(sum('settled_text'))],['Eventos / reversões',`${events??0} / ${reversals??0}`]].map(([l,v])=><div key={l} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{l}</div><div className="mt-2 text-2xl font-semibold">{v}</div></div>)}
  </div>
  <nav className="mt-6 flex flex-wrap gap-2 text-sm" aria-label="Filtro por status">{FILTERS.map(f=><Link key={f} href={f==='all'?'/app/financeiro':`/app/financeiro?status=${f}`} className={`rounded-lg border px-3 py-1 ${filter===f?'border-emerald-400 text-emerald-300':'border-slate-700 text-slate-300'}`}>{f==='all'?'Todos':STATUS[f]}{f!=='all'&&counts.has(f)?` (${counts.get(f)})`:''}</Link>)}</nav>
  {error?<p role="alert" className="mt-4 text-amber-300">Não foi possível consultar os casos.</p>:!cases?.length?<p className="mt-4 rounded-xl border border-slate-800 p-5 text-sm text-slate-400">Nenhum caso de conciliação{filter!=='all'?' neste status':''}. Casos são criados quando a comissão esperada é publicada ou evidência financeira é registrada.</p>:
  <div className="mt-4 overflow-x-auto rounded-xl border border-slate-800"><table className="min-w-full text-left text-sm"><thead className="bg-slate-900 text-slate-400"><tr><th className="p-3">Proposta</th><th className="p-3">Componente</th><th className="p-3">Esperado</th><th className="p-3">Reportado</th><th className="p-3">Recebido</th><th className="p-3">Diferença</th><th className="p-3">Status</th><th className="p-3"></th></tr></thead>
  <tbody>{cases.map(c=><tr key={c.id} className="border-t border-slate-800"><td className="p-3"><Link className="underline" href={`/app/propostas/${c.proposal_id}`}>{c.proposal_id.slice(0,8)}…</Link></td><td className="p-3">{c.component_type??'—'}</td><td className="p-3">{formatBRL(c.expected_text)}</td><td className="p-3">{formatBRL(c.reported_text)}</td><td className="p-3">{formatBRL(c.settled_text)}</td><td className="p-3">{formatBRL(c.divergence_text)}</td><td className="p-3">{STATUS[c.status]??c.status}</td><td className="p-3"><Link className="text-emerald-300 underline" href={`/app/financeiro/casos/${c.id}`}>Abrir ledger</Link></td></tr>)}</tbody></table></div>}
  <div className="mt-6 rounded-xl border border-amber-900/60 bg-slate-900 p-5">
   <h2 className="font-semibold">Financial Truth Gate</h2>
   <p className="mt-2 text-sm text-slate-400">O ledger é append-only: correções são reversões compensatórias (total ou parcial) vinculadas ao evento original, com fonte e referência obrigatórias. Valores de conciliação são derivados do ledger e não podem ser editados; a resolução humana registra apenas a justificativa.</p>
  </div>
 </section>
}
