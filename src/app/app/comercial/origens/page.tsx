import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createProvider, setActive, updateProvider } from '../actions'

const field = 'rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card = 'rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn = 'rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost = 'rounded-lg border border-slate-700 px-3 py-2 text-sm'
const TYPES: Record<string,string> = { bank_direct:'Banco direto', master:'Master', promotora:'Promotora', correspondent:'Correspondente', partner:'Parceiro', other:'Outro' }

export default async function OriginsPage() {
  const { supabase, membership } = await requireAppContext()
  const canEdit = atLeast(membership.role, 'manager')
  if (!atLeast(membership.role, 'supervisor')) return <section><p>Sem permissão.</p></section>
  const { data: rows } = await supabase.from('organization_providers').select('id,name,provider_type,is_active').order('name')
  const active = (rows ?? []).filter(r => r.is_active).length
  return <section>
    <Link href="/app/comercial" className="text-sm text-slate-400 underline">← Voltar ao Comercial</Link>
    <div className="mt-3"><h1 className="text-3xl font-semibold">Empresas de origem de terceiros</h1><p className="mt-2 text-sm text-slate-400">Cadastre aqui somente a empresa externa usada quando uma tabela/produção não é própria da sua operação.</p><p className="mt-1 text-xs text-slate-500">{active} ativas · {(rows ?? []).length} no total</p></div>

    {canEdit && <form action={createProvider} className={`${card} mt-5 grid gap-2 md:grid-cols-3`}>
      <input type="hidden" name="return_to" value="/app/comercial/origens" />
      <input required name="name" maxLength={120} placeholder="Nome da empresa de origem" className={`${field} md:col-span-2`} />
      <select name="provider_type" defaultValue="master" className={field}>{Object.entries(TYPES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</select>
      <p className="text-xs text-slate-500 md:col-span-2">A classificação é apenas descritiva da empresa externa. Ela não define quem é correspondente de quem.</p>
      <SubmitButton className={`${btn} md:justify-self-end`}>Cadastrar empresa</SubmitButton>
    </form>}

    <div className={`${card} mt-4`}>
      {!rows?.length ? <p className="text-sm text-slate-400">Nenhuma empresa de origem cadastrada.</p> :
      <div className="space-y-2">{rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-800 p-3">
        <div><strong>{row.name}</strong><span className="ml-2 text-xs text-slate-500">· {TYPES[row.provider_type] ?? row.provider_type}</span><span className={`ml-2 text-xs ${row.is_active ? 'text-emerald-300' : 'text-slate-500'}`}>{row.is_active ? 'Ativa' : 'Inativa'}</span></div>
        {canEdit && <div className="flex items-center gap-3">
          <details><summary className="cursor-pointer text-xs text-slate-300 underline">Editar</summary><form action={updateProvider} className="mt-2 grid min-w-72 gap-2"><input type="hidden" name="return_to" value="/app/comercial/origens" /><input type="hidden" name="id" value={row.id} /><input required name="name" defaultValue={row.name} className={field} /><select name="provider_type" defaultValue={row.provider_type} className={field}>{Object.entries(TYPES).map(([k,v]) => <option key={k} value={k}>{v}</option>)}</select><p className="text-[11px] text-slate-500">Você pode corrigir a classificação depois, por exemplo de Correspondente para Promotora.</p><SubmitButton className={ghost}>Salvar alterações</SubmitButton></form></details>
          <form action={setActive}><input type="hidden" name="return_to" value="/app/comercial/origens" /><input type="hidden" name="kind" value="provider" /><input type="hidden" name="id" value={row.id} /><input type="hidden" name="active" value={row.is_active ? 'false' : 'true'} /><SubmitButton className={ghost}>{row.is_active ? 'Inativar' : 'Reativar'}</SubmitButton></form>
        </div>}
      </div>)}</div>}
    </div>
  </section>
}
