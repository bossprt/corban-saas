import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'

function maskCpf(value:string|null){if(!value)return '—';const d=value.replace(/\D/g,'');return d.length===11?`***.${d.slice(3,6)}.${d.slice(6,9)}-**`:'***.***.***-**'}
export default async function CustomerDetail({params}:{params:Promise<{id:string}>}){
 const {id}=await params
 const {supabase}=await requireAppContext()
 const [{data:customer},{data:proposals},{data:documents}]=await Promise.all([
  supabase.from('clients').select('id,full_name,cpf,phone,email,created_at').eq('id',id).is('deleted_at',null).maybeSingle(),
  supabase.from('proposals_v2').select('id,status,requested_amount,created_at').eq('customer_id',id).order('created_at',{ascending:false}).limit(20),
  supabase.from('customer_documents').select('id,status,created_at,document_type_id').eq('customer_id',id).order('created_at',{ascending:false}).limit(20),
 ])
 if(!customer)notFound()
 return <section>
  <div className="mb-6"><Link href="/app/clientes" className="text-sm text-slate-400 hover:text-white">← Clientes</Link><h1 className="mt-3 text-3xl font-semibold">{customer.full_name}</h1><p className="mt-2 text-sm text-slate-400">Customer 360 · CPF {maskCpf(customer.cpf)}</p></div>
  <div className="grid gap-4 md:grid-cols-3"><div className="rounded-xl border border-slate-800 bg-slate-900 p-4"><div className="text-xs text-slate-500">Telefone</div><div className="mt-1">{customer.phone??'—'}</div></div><div className="rounded-xl border border-slate-800 bg-slate-900 p-4"><div className="text-xs text-slate-500">E-mail</div><div className="mt-1">{customer.email??'—'}</div></div><div className="rounded-xl border border-slate-800 bg-slate-900 p-4"><div className="text-xs text-slate-500">Desde</div><div className="mt-1">{new Date(customer.created_at).toLocaleDateString('pt-BR')}</div></div></div>
  <div className="mt-6 grid gap-6 xl:grid-cols-2"><div className="rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Propostas</h2><div className="mt-3 space-y-2">{!proposals?.length?<p className="text-sm text-slate-500">Nenhuma proposta.</p>:proposals.map(p=><Link key={p.id} href={`/app/propostas/${p.id}`} className="flex justify-between rounded-lg border border-slate-800 p-3 text-sm hover:border-slate-700"><span>{p.id.slice(0,8)} · {p.status}</span><span>{p.requested_amount?Number(p.requested_amount).toLocaleString('pt-BR',{style:'currency',currency:'BRL'}):'—'}</span></Link>)}</div></div>
  <div className="rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Documentos</h2><p className="mt-2 text-xs text-slate-500">Arquivos físicos permanecem no cofre privado; aqui mostramos somente metadados autorizados.</p><div className="mt-3 space-y-2">{!documents?.length?<p className="text-sm text-slate-500">Nenhum documento.</p>:documents.map(d=><div key={d.id} className="rounded-lg border border-slate-800 p-3 text-sm"><span>{d.status}</span><span className="float-right text-slate-500">{new Date(d.created_at).toLocaleDateString('pt-BR')}</span></div>)}</div></div></div>
 </section>
}
