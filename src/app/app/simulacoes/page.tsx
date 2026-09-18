import { requireAppContext } from '@/lib/appContext'
import { createProposalFromSimulation, createSimulation } from './actions'

function brl(value: number | string | null) {
  return value === null ? '—' : Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}

export default async function SimulationsPage() {
  const { supabase } = await requireAppContext()
  const [customersResult, versionsResult, simulationsResult, proposalsResult] = await Promise.all([
    supabase.from('clients').select('id,full_name').is('deleted_at', null).order('full_name').limit(200),
    supabase.from('product_table_versions')
      .select('id,version,product_table_id,term_min,term_max,rate,coefficient')
      .eq('status', 'published').order('published_at', { ascending: false }).limit(100),
    supabase.from('simulations')
      .select('id,customer_id,product_table_version_id,status,requested_amount,installment_amount,term,rate,created_at')
      .order('created_at', { ascending: false }).limit(100),
    supabase.from('proposals_v2').select('id,simulation_id').not('simulation_id', 'is', null),
  ])

  const customerNames = new Map((customersResult.data ?? []).map(c => [c.id, c.full_name]))
  const proposalBySimulation = new Map((proposalsResult.data ?? []).map(p => [p.simulation_id, p.id]))

  return <section>
    <div className="mb-6">
      <h1 className="text-3xl font-semibold">Simulações</h1>
      <p className="mt-2 text-sm text-slate-400">Simule somente sobre versões de tabela publicadas no tenant.</p>
    </div>

    <form action={createSimulation} className="mb-8 grid gap-3 rounded-2xl border border-slate-800 bg-slate-900 p-5 md:grid-cols-4">
      <select required name="customer_id" className="field md:col-span-2" defaultValue="">
        <option value="" disabled>Selecione o cliente</option>
        {customersResult.data?.map(c => <option key={c.id} value={c.id}>{c.full_name}</option>)}
      </select>
      <select required name="product_table_version_id" className="field md:col-span-2" defaultValue="">
        <option value="" disabled>Selecione a tabela publicada</option>
        {versionsResult.data?.map(v => <option key={v.id} value={v.id}>Tabela {v.product_table_id.slice(0, 8)} · v{v.version} · prazo {v.term_min ?? '—'}–{v.term_max ?? '—'}</option>)}
      </select>
      <input required name="requested_amount" inputMode="decimal" placeholder="Valor solicitado" className="field md:col-span-2"/>
      <input required name="term" inputMode="numeric" placeholder="Prazo" className="field"/>
      <button className="rounded-lg bg-emerald-500 px-4 py-2.5 text-sm font-semibold text-slate-950">Calcular e registrar</button>
    </form>

    <div className="grid gap-3">
      {simulationsResult.data?.map(s => {
        const proposalId = proposalBySimulation.get(s.id)
        return <article key={s.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div>
              <div className="font-medium">{customerNames.get(s.customer_id) ?? 'Cliente'}</div>
              <div className="mt-1 text-xs text-slate-500">{new Date(s.created_at).toLocaleString('pt-BR')} · {s.status}</div>
            </div>
            <div className="grid grid-cols-3 gap-5 text-sm">
              <div><span className="block text-xs text-slate-500">Solicitado</span>{brl(s.requested_amount)}</div>
              <div><span className="block text-xs text-slate-500">Parcela</span>{brl(s.installment_amount)}</div>
              <div><span className="block text-xs text-slate-500">Prazo</span>{s.term ?? '—'}</div>
            </div>
            {proposalId
              ? <span className="rounded-full bg-emerald-500/10 px-3 py-1.5 text-xs text-emerald-400">Proposta criada</span>
              : <form action={createProposalFromSimulation}>
                  <input type="hidden" name="simulation_id" value={s.id}/>
                  <button className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-semibold text-white hover:bg-blue-500">Criar proposta</button>
                </form>}
          </div>
        </article>
      })}
      {!simulationsResult.data?.length && <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Nenhuma simulação registrada.</div>}
    </div>
  </section>
}
