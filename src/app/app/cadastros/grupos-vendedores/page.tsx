import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createSellerClassification, updateSellerClassification } from './actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function SellerGroupsPage({searchParams}:{searchParams?:Promise<{ok?:string;erro?:string}>}){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const sp=await searchParams
  const {data:groups}=await supabase.from('seller_groups').select('id,name,is_active,sort_order').order('sort_order').order('name')

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Grupos de vendedores</h1>
    <p className="mt-2 max-w-4xl text-sm text-slate-400">Classificação interna dos vendedores. Use qualquer nomenclatura que faça sentido para sua operação: Básico, Bronze, Prata, Ouro, Diamante, Elite, Novo etc. Este grupo, sozinho, não altera comissão, bônus ou prioridade.</p>
    <div className="mt-4 rounded-xl border border-amber-500/20 bg-amber-500/5 p-4 text-sm text-amber-100">
      O grupo serve para segmentar e filtrar vendedores. Se no futuro um grupo receber vantagem, isso será definido por uma regra separada de comissão, bônus, campanha ou atendimento.
    </div>

    {(sp?.ok||sp?.erro)&&<div className="mt-4 rounded-lg border border-slate-800 p-3 text-sm">{sp.ok==='criado'?'Grupo de vendedores cadastrado.':sp.ok==='atualizado'?'Grupo de vendedores atualizado.':sp.erro==='duplicado'?'Já existe um grupo com este nome.':'Não foi possível concluir.'}</div>}

    {canEdit&&<form action={createSellerClassification} className={card+' mt-5 grid gap-3 md:grid-cols-[1fr_auto]'}>
      <label className="text-xs text-slate-400">Nome do grupo
        <input required name="name" maxLength={80} placeholder="Ex.: Básico, Bronze, Prata, Ouro, Diamante" className={field+' mt-1 block w-full'}/>
      </label>
      <div className="flex items-end"><SubmitButton className={btn}>Cadastrar grupo</SubmitButton></div>
    </form>}

    <div className="mt-5 space-y-3">
      {(groups??[]).map(g=><div key={g.id} className={card}>
        <form action={updateSellerClassification} className="flex flex-wrap items-end gap-3">
          <input type="hidden" name="id" value={g.id}/>
          <input type="hidden" name="active" value={g.is_active?'true':'false'}/>
          <label className="min-w-64 flex-1 text-xs text-slate-400">Classificação
            <input required name="name" defaultValue={g.name} maxLength={80} className={field+' mt-1 block w-full'} disabled={!canEdit}/>
          </label>
          <div className={'text-xs '+(g.is_active?'text-emerald-300':'text-slate-500')}>{g.is_active?'Ativo':'Inativo'}</div>
          {canEdit&&<SubmitButton className={ghost}>Salvar nome</SubmitButton>}
        </form>
        {canEdit&&<form action={updateSellerClassification} className="mt-3">
          <input type="hidden" name="id" value={g.id}/>
          <input type="hidden" name="name" value={g.name}/>
          <input type="hidden" name="active" value={g.is_active?'false':'true'}/>
          <SubmitButton className={ghost}>{g.is_active?'Inativar grupo':'Reativar grupo'}</SubmitButton>
        </form>}
      </div>)}
      {!(groups??[]).length&&<div className={card}><p className="text-sm text-slate-400">Nenhum grupo de vendedores cadastrado.</p></div>}
    </div>
  </section>
}
