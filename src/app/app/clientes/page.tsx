import { createCustomer } from './actions'
import { requireAppContext } from '@/lib/appContext'

function maskCpf(value: string | null) {
  if (!value) return '—'
  const digits = value.replace(/\D/g, '')
  if (digits.length !== 11) return '***.***.***-**'
  return `***.${digits.slice(3, 6)}.${digits.slice(6, 9)}-**`
}

export default async function CustomersPage() {
  const { supabase } = await requireAppContext()
  const { data: customers } = await supabase
    .from('clients')
    .select('id,full_name,cpf,phone,email,created_at')
    .is('deleted_at', null)
    .order('created_at', { ascending: false })
    .limit(100)

  return <section>
    <div className="mb-6"><h1 className="text-3xl font-semibold">Clientes</h1><p className="mt-2 text-sm text-slate-400">Customer 360 do tenant atual.</p></div>
    <form action={createCustomer} className="mb-8 grid gap-3 rounded-2xl border border-slate-800 bg-slate-900 p-5 md:grid-cols-5">
      <input required name="full_name" placeholder="Nome completo" className="field md:col-span-2"/>
      <input required name="cpf" inputMode="numeric" autoComplete="off" placeholder="CPF" className="field"/>
      <input name="phone" placeholder="Telefone" className="field"/>
      <input name="email" type="email" placeholder="E-mail" className="field"/>
      <button className="rounded-lg bg-emerald-500 px-4 py-2.5 text-sm font-semibold text-slate-950 md:col-span-5 md:justify-self-end">Cadastrar cliente</button>
    </form>
    <div className="overflow-hidden rounded-2xl border border-slate-800 bg-slate-900">
      <div className="overflow-x-auto"><table className="w-full text-left text-sm">
        <thead className="border-b border-slate-800 text-slate-400"><tr><th className="p-4">Cliente</th><th className="p-4">CPF</th><th className="p-4">Telefone</th><th className="p-4">E-mail</th></tr></thead>
        <tbody>{customers?.map(c => <tr key={c.id} className="border-b border-slate-800/60 last:border-0"><td className="p-4 font-medium">{c.full_name}</td><td className="p-4 text-slate-400">{maskCpf(c.cpf)}</td><td className="p-4 text-slate-400">{c.phone ?? '—'}</td><td className="p-4 text-slate-400">{c.email ?? '—'}</td></tr>)}{!customers?.length && <tr><td colSpan={4} className="p-8 text-center text-slate-500">Nenhum cliente cadastrado.</td></tr>}</tbody>
      </table></div>
    </div>
  </section>
}
