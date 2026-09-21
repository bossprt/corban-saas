import { requireAppContext } from '@/lib/appContext'
import { closeSimulation, createProposalFromSimulation, createSimulation } from './actions'
import { SubmitButton } from '@/components/SubmitButton'
import { effectiveContractTypes } from '@/lib/contract-types'
import { formatBRL } from '@/lib/finance/ledger'
import { atLeast } from '@/lib/rbac'

const SIM_STATUS: Record<string, string> = { draft: 'Rascunho', calculated: 'Calculada', selected: 'Virou proposta', expired: 'Expirada', cancelled: 'Cancelada' }

function brl(value: number | string | null) {
  return value === null ? 'Não calculado' : formatBRL(String(value))
}

export default async function SimulationsPage() {
  const { supabase, membership } = await requireAppContext()
  const canCloseSimulation = atLeast(membership.role, 'supervisor')
  const [tablesResult, customersResult, versionsResult, simulationsResult, proposalsResult, typesResult, typeSettingsResult, conditionsResult] = await Promise.all([
    supabase.from('product_tables').select('id,name,code'),
    supabase.from('clients').select('id,full_name').is('deleted_at', null).order('full_name').limit(200),
    supabase.from('product_table_versions')
      .select('id,version,product_table_id,term_min,term_max,rate,coefficient')
      .eq('status', 'published').order('published_at', { ascending: false }).limit(100),
    supabase.from('simulations')
      .select('id,customer_id,product_table_version_id,status,requested_amount,installment_amount,term,rate,created_at')
      .order('created_at', { ascending: false }).limit(100),
    supabase.from('proposals_v2').select('id,simulation_id').not('simulation_id', 'is', null),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
    supabase.from('commercial_conditions').select('product_table_version_id'),
  ])
  const enabledTypes=effectiveContractTypes((typesResult.data ?? []) as {id:string;name:string;tech_key:string;is_active:boolean;organization_id:string|null}[], (typeSettingsResult.data ?? []) as {contract_type_id:string;is_enabled:boolean;use_in_pipeline:boolean;use_in_commission:boolean}[], 'general')
  const conditionCount = new Map<string, number>()
  for (const c of conditionsResult.data ?? []) conditionCount.set(c.product_table_version_id, (conditionCount.get(c.product_table_version_id) ?? 0) + 1)

  const tableNames = new Map((tablesResult.data ?? []).map(t => [t.id, t.name || t.code]))
  const customerNames = new Map((customersResult.data ?? []).map(c => [c.id, c.full_name]))
  const proposalBySimulation = new Map((proposalsResult.data ?? []).map(p => [p.simulation_id, p.id]))

  return <section>
    <div className="mb-6">
      <h1 className="text-3xl font-semibold">Simulações</h1>
      <p className="mt-2 text-sm text-slate-400">Simule somente sobre versões de tabela publicadas no tenant.</p>
    </div>

    {!customersResult.data?.length && <p className="mb-4 rounded-xl border border-slate-800 p-4 text-sm text-slate-400">Para simular, primeiro converta um lead em cliente (Leads) ou cadastre um cliente (Clientes).</p>}
    {!versionsResult.data?.length && <p className="mb-4 rounded-xl border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-amber-200">Nenhuma tabela comercial publicada. Peça ao administrador para publicar uma tabela antes de simular.</p>}
    <form action={createSimulation} className="mb-8 grid gap-3 rounded-2xl border border-slate-800 bg-slate-900 p-5 md:grid-cols-4">
      <select required name="customer_id" className="field md:col-span-2" defaultValue="">
        <option value="" disabled>Selecione o cliente</option>
        {customersResult.data?.map(c => <option key={c.id} value={c.id}>{c.full_name}</option>)}
      </select>
      <select required name="product_table_version_id" className="field md:col-span-2" defaultValue="">
        <option value="" disabled>Selecione a tabela publicada</option>
        {versionsResult.data?.map(v => <option key={v.id} value={v.id}>{tableNames.get(v.product_table_id) ?? 'Tabela'} · v{v.version} · {conditionCount.has(v.id) ? `${conditionCount.get(v.id)} condição(ões)` : `prazo ${v.term_min ?? '—'}–${v.term_max ?? '—'}`}</option>)}
      </select>
      <select name="contract_type_id" defaultValue="" className="field md:col-span-2">
        <option value="">Tipo de Contrato (tabelas com condições)</option>
        {enabledTypes.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
      </select>
      <input required name="requested_amount" inputMode="decimal" placeholder="Valor solicitado" className="field md:col-span-2"/>
      <input required name="term" inputMode="numeric" placeholder="Prazo" className="field"/>
      <SubmitButton className="rounded-lg bg-emerald-500 px-4 py-2.5 text-sm font-semibold text-slate-950" pendingText="Calculando...">Calcular e registrar</SubmitButton>
    </form>

    <div className="grid gap-3">
      {simulationsResult.data?.map(s => {
        const proposalId = proposalBySimulation.get(s.id)
        return <article key={s.id} className="rounded-xl border border-slate-800 bg-slate-900 p-5">
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div>
              <div className="font-medium">{customerNames.get(s.customer_id) ?? 'Cliente'}</div>
              <div className="mt-1 text-xs text-slate-500">{new Date(s.created_at).toLocaleString('pt-BR')} · {SIM_STATUS[s.status] ?? s.status}</div>
            </div>
            <div className="grid grid-cols-3 gap-5 text-sm">
              <div><span className="block text-xs text-slate-500">Solicitado</span>{brl(s.requested_amount)}</div>
              <div><span className="block text-xs text-slate-500">Parcela</span>{brl(s.installment_amount)}</div>
              <div><span className="block text-xs text-slate-500">Prazo</span>{s.term ?? '—'}</div>
            </div>
            <div className="flex flex-wrap gap-2">
              {proposalId
                ? <span className="rounded-full bg-emerald-500/10 px-3 py-1.5 text-xs text-emerald-400">Proposta criada</span>
                : s.status === 'calculated' && <form action={createProposalFromSimulation}>
                    <input type="hidden" name="simulation_id" value={s.id}/>
                    <SubmitButton className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-semibold text-white hover:bg-blue-500" pendingText="Criando...">Criar proposta</SubmitButton>
                  </form>}
              {canCloseSimulation && !proposalId && s.status === 'calculated' && <>
                <form action={closeSimulation}>
                  <input type="hidden" name="simulation_id" value={s.id}/>
                  <input type="hidden" name="target_status" value="expired"/>
                  <SubmitButton className="rounded-lg border border-slate-700 px-3 py-2 text-xs font-semibold" pendingText="Encerrando...">Expirar</SubmitButton>
                </form>
                <form action={closeSimulation}>
                  <input type="hidden" name="simulation_id" value={s.id}/>
                  <input type="hidden" name="target_status" value="cancelled"/>
                  <SubmitButton className="rounded-lg border border-red-500/40 px-3 py-2 text-xs font-semibold text-red-200" pendingText="Cancelando...">Cancelar</SubmitButton>
                </form>
              </>}
            </div>
          </div>
        </article>
      })}
      {!simulationsResult.data?.length && <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 text-center text-slate-500">Nenhuma simulação ainda.</div>}
    </div>
  </section>
}
