import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createBank, renameCatalogItem, setActive } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function InstitutionsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>
  const { data: rows } = await supabase.from('organization_banks').select('id,name,is_active').order('name')
  const active = (rows ?? []).filter(r => r.is_active).length
  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Cadastros</Link>
    <div className="mt-3 flex flex-wrap items-end justify-between gap-3"><div><h1 className="text-3xl font-semibold">Instituições / Origens</h1><p className="mt-2 text-sm text-slate-400">Banco ou instituição que fica no lado de origem da operação. Exemplos: Daycoval, NASP, Hope.</p></div><span className="text-sm text-slate-400">{active} ativas · {(rows ?? []).length} no total</span></div>

    {canEdit && <form action={createBank} className={`${card} mt-5 flex flex-wrap gap-2`}>
      <input type="hidden" name="return_to" value="/app/comercial/instituicoes" />
      <input required name="name" maxLength={120} placeholder="Nome da instituição / origem" className={`${field} min-w-64 flex-1`} />
      <SubmitButton className={btn}>Cadastrar instituição</SubmitButton>
    </form>}

    <div className={`${card} mt-4`}>
      {!rows?.length ? <p className="text-sm text-slate-400">Nenhuma instituição cadastrada.</p> :
      <div className="space-y-2">{rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-800 p-3">
        <div><strong>{row.name}</strong><span className={`ml-2 text-xs ${row.is_active ? 'text-emerald-300' : 'text-slate-500'}`}>{row.is_active ? 'Ativa' : 'Inativa'}</span></div>
        {canEdit && <div className="flex items-center gap-3">
          <details><summary className="cursor-pointer text-xs text-slate-300 underline">Editar</summary><form action={renameCatalogItem} className="mt-2 flex gap-2"><input type="hidden" name="return_to" value="/app/comercial/instituicoes" /><input type="hidden" name="kind" value="bank" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className={field} /><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>
          <form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/instituicoes" /><input type="hidden" name="kind" value="bank" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form>
        </div>}
      </div>)}</div>}
    </div>
  </section>
}
