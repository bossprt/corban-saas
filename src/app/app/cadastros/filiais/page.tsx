import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createBranch,setBranchActive } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function BranchesPage({searchParams}:{searchParams?:Promise<{ok?:string;erro?:string}>}){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const sp=await searchParams
  const {data:branches}=await supabase.from('organization_branches').select('id,code,name,branch_type,is_active').order('branch_type').order('name')

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Matriz e filiais</h1>
    <p className="mt-2 text-sm text-slate-400">Cadastre aqui as unidades da organização. O vendedor apenas escolhe a unidade na própria ficha.</p>

    {(sp?.ok||sp?.erro)&&<div className="mt-4 rounded-lg border border-slate-800 p-3 text-sm">{sp.ok==='criado'?'Filial cadastrada.':sp.ok==='atualizado'?'Filial atualizada.':sp.erro==='duplicado'?'Já existe uma filial com este código.':'Não foi possível concluir.'}</div>}

    {canEdit&&<form action={createBranch} className={card+' mt-5 grid gap-3 md:grid-cols-[180px_1fr_auto]'}>
      <input required name="code" maxLength={30} placeholder="Código" className={field}/>
      <input required name="name" maxLength={120} placeholder="Nome da filial" className={field}/>
      <SubmitButton className={btn}>Cadastrar filial</SubmitButton>
    </form>}

    <div className="mt-5 overflow-hidden rounded-2xl border border-slate-800">
      {(branches??[]).map(b=><div key={b.id} className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-800 bg-slate-900 p-4 last:border-b-0">
        <div><div className="font-semibold">{b.branch_type==='matrix'?'Matriz · ':'Filial · '}{b.name}</div><div className="mt-1 text-xs text-slate-500">Código: {b.code} · {b.is_active?'Ativa':'Inativa'}</div></div>
        {canEdit&&b.branch_type==='branch'&&<form action={setBranchActive}><input type="hidden" name="id" value={b.id}/><input type="hidden" name="active" value={b.is_active?'false':'true'}/><SubmitButton className={ghost}>{b.is_active?'Inativar':'Reativar'}</SubmitButton></form>}
      </div>)}
    </div>
  </section>
}
