import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createCommissionGroup, renameCatalogItem, setActive } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
export default async function CommissionGroupsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>
  const { data: rows } = await supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name')
  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Grupos de comissão</h1>
    <p className="mt-2 max-w-4xl text-sm text-slate-400">Cada grupo representa uma coluna de repasse. Crie apenas os nomes que sua operação usa, como Balcão, Corretores, Parceiros ou Indicadores.</p>
    <div className="mt-4 rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4 text-sm">
      <strong>Como funciona:</strong>
      <p className="mt-2 text-slate-300">A empresa informa quanto recebeu na tabela/condição comercial. Depois, para cada grupo, informa qual percentual daquele valor recebido será repassado.</p>
      <p className="mt-2 text-xs text-slate-400">Ex.: empresa recebe 10%. Balcão = 100% → 10%. Parceiro = 80% → 8%. Corretor = 65% → 6,5%.</p>
    </div>

    {canEdit && <form action={createCommissionGroup} className={`${card} mt-5 space-y-4`}>
      <input type="hidden" name="return_to" value="/app/comercial/grupos" />
      <div>
        <label className="text-sm font-medium">Nome do grupo</label>
        <input required name="name" maxLength={80} placeholder="Ex.: Balcão, Corretores, Parceiros, Indicadores" className={`${field} mt-2 w-full`} />
        <p className="mt-2 text-xs text-slate-500">Esse nome será usado como identificação/coluna de repasse nas condições comerciais e nas importações.</p>
      </div>
      <SubmitButton className={btn}>Cadastrar grupo</SubmitButton>
    </form>}

    <div className={`${card} mt-4`}>
      {!rows?.length ? <p className="text-sm text-slate-400">Nenhum grupo cadastrado.</p> : <div className="space-y-2">{rows.map(row => <div key={row.id} className="rounded-xl border border-slate-800 p-3">
        <div className="flex flex-wrap items-center justify-between gap-3"><div><strong>{row.name}</strong><span className="ml-2 text-xs text-slate-500">· coluna de repasse</span><span className={`ml-2 text-xs ${row.is_active ? 'text-emerald-300' : 'text-slate-500'}`}>{row.is_active ? 'Ativo' : 'Inativo'}</span></div>
        {canEdit && <div className="flex items-center gap-3"><details><summary className="cursor-pointer text-xs text-slate-300 underline">Editar nome</summary><form action={renameCatalogItem} className="mt-2 flex gap-2"><input type="hidden" name="return_to" value="/app/comercial/grupos" /><input type="hidden" name="kind" value="group" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className={field} /><SubmitButton className={ghost}>Salvar</SubmitButton></form></details><form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/grupos" /><input type="hidden" name="kind" value="group" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form></div>}</div>
      </div>)}</div>}
    </div>
  </section>
}
