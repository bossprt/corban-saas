import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createCommissionGroup, renameCatalogItem, setActive } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
const BASIS: Record<string,string> = {
  percent_of_received_commission: 'Percentual da comissão que a empresa recebe',
  percent_of_production: 'Percentual direto sobre o valor da operação',
}

export default async function CommissionGroupsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>
  const { data: rows } = await supabase.from('commission_groups').select('id,name,calculation_basis,is_active').order('sort_order').order('name')
  return <section>
    <Link href="/app/comercial" className="text-sm text-slate-400 underline">← Voltar ao Comercial</Link>
    <h1 className="mt-3 text-3xl font-semibold">Grupos de comissão</h1>
    <p className="mt-2 text-sm text-slate-400">O nome identifica quem recebe. Você não precisa escolher um “tipo” técnico do grupo.</p>

    {canEdit && <form action={createCommissionGroup} className={`${card} mt-5 space-y-4`}>
      <input type="hidden" name="return_to" value="/app/comercial/grupos" />
      <input type="hidden" name="kind" value="other" />
      <div><label className="text-sm font-medium">Nome do grupo</label><input required name="name" maxLength={80} placeholder="Ex.: Corretores, Parceiros, Balcão, Indicadores" className={`${field} mt-2 w-full`} /></div>
      <fieldset><legend className="text-sm font-medium">Como o percentual desse grupo deve ser lido?</legend>
        <div className="mt-2 grid gap-3 md:grid-cols-2">
          <label className="cursor-pointer rounded-xl border border-emerald-500/30 bg-emerald-500/5 p-4"><input type="radio" name="calculation_basis" value="percent_of_received_commission" defaultChecked className="mr-2" /><strong>% da comissão recebida</strong><p className="mt-1 text-xs text-slate-400">Ex.: empresa recebe 10%; grupo recebe 65% dessa comissão → 6,5% efetivo da operação.</p></label>
          <label className="cursor-pointer rounded-xl border border-slate-800 p-4"><input type="radio" name="calculation_basis" value="percent_of_production" className="mr-2" /><strong>% direto da operação</strong><p className="mt-1 text-xs text-slate-400">Ex.: grupo recebe diretamente 4% sobre o valor produzido. Use apenas quando sua regra comercial for assim.</p></label>
        </div>
      </fieldset>
      <SubmitButton className={btn}>Cadastrar grupo</SubmitButton>
    </form>}

    <div className={`${card} mt-4`}>
      {!rows?.length ? <p className="text-sm text-slate-400">Nenhum grupo cadastrado.</p> : <div className="space-y-2">{rows.map(row => <div key={row.id} className="rounded-xl border border-slate-800 p-3">
        <div className="flex flex-wrap items-center justify-between gap-3"><div><strong>{row.name}</strong><span className="ml-2 text-xs text-slate-500">· {BASIS[row.calculation_basis] ?? row.calculation_basis}</span><span className={`ml-2 text-xs ${row.is_active ? 'text-emerald-300' : 'text-slate-500'}`}>{row.is_active ? 'Ativo' : 'Inativo'}</span></div>
        {canEdit && <div className="flex items-center gap-3"><details><summary className="cursor-pointer text-xs text-slate-300 underline">Editar nome</summary><form action={renameCatalogItem} className="mt-2 flex gap-2"><input type="hidden" name="return_to" value="/app/comercial/grupos" /><input type="hidden" name="kind" value="group" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className={field} /><SubmitButton className={ghost}>Salvar</SubmitButton></form></details><form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/grupos" /><input type="hidden" name="kind" value="group" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form></div>}</div>
      </div>)}</div>}
    </div>
  </section>
}
