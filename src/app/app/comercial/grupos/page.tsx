import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createCommissionGroup, saveCommissionGroupConfiguration, setActive } from '../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function CommissionGroupsPage(){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')

  const [groups,components,limits]=await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_component_types').select('id,tech_key,name,sort_order,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('commission_group_component_limits').select('group_id,component_type_id,max_received_share_pct'),
  ])

  const limitMap=new Map((limits.data??[]).map(x=>[x.group_id+'|'+x.component_type_id,String(x.max_received_share_pct)]))
  const configured=new Set((limits.data??[]).map(x=>x.group_id))

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
    <h1 className="mt-3 text-3xl font-semibold">Grupos de comissão</h1>
    <p className="mt-2 max-w-4xl text-sm text-slate-400">Defina quanto de cada componente recebido pela empresa pode entrar no cálculo de repasse de cada grupo.</p>

    <div className="mt-4 rounded-xl border border-emerald-500/20 bg-emerald-500/5 p-4 text-sm">
      <strong>Leitura dos percentuais</strong>
      <p className="mt-2 text-slate-300"><strong>100%</strong> = pode usar tudo o que a empresa recebeu naquele componente. <strong>0%</strong> = aquele componente não será repassado. Valores intermediários, como 90%, limitam a base a esse percentual.</p>
      <p className="mt-2 text-xs text-slate-400">Ex.: a empresa recebeu 10% à vista. Se o grupo estiver em 90%, no máximo 9% da operação entra como base para esse grupo. O percentual final pago ao vendedor é tratado em outra regra.</p>
    </div>

    {canEdit&&<form action={createCommissionGroup} className={card+' mt-5'}>
      <h2 className="text-lg font-semibold">Cadastrar grupo de comissão</h2>
      <div className="mt-4">
        <label className="text-sm font-medium">Nome do grupo</label>
        <input required name="name" maxLength={80} placeholder="Ex.: Balcão, Corretores, Parceiros, Subestabelecido" className={field+' mt-2 w-full'}/>
      </div>
      <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {(components.data??[]).map(c=><label key={c.id} className="rounded-xl border border-slate-800 p-3 text-xs text-slate-400">
          {c.name} — máximo do recebido (%)
          <input required name={'component_'+c.id} inputMode="decimal" placeholder="0 a 100" className={field+' mt-2 w-full'}/>
        </label>)}
      </div>
      <p className="mt-3 text-xs text-slate-500">Todos os componentes devem ser definidos. Use 0 quando o grupo não deve receber aquele componente.</p>
      <SubmitButton className={btn+' mt-4'}>Cadastrar grupo</SubmitButton>
    </form>}

    <div className="mt-5 space-y-4">
      {!(groups.data??[]).length&&<div className={card}><p className="text-sm text-slate-400">Nenhum grupo cadastrado.</p></div>}
      {(groups.data??[]).map(group=>{
        const hasConfig=configured.has(group.id)
        return <div key={group.id} className={card}>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h2 className="text-lg font-semibold">{group.name}</h2>
                <span className={'text-xs '+(group.is_active?'text-emerald-300':'text-slate-500')}>{group.is_active?'Ativo':'Inativo'}</span>
                <span className={'text-xs '+(hasConfig?'text-sky-300':'text-amber-300')}>{hasConfig?'Configurado':'Configuração pendente'}</span>
              </div>
              <p className="mt-1 text-xs text-slate-500">Limites por componente sobre 100% do que a empresa recebe.</p>
            </div>
            {canEdit&&<form action={setActive}>
              <input type="hidden" name="return_to" value="/app/comercial/grupos"/>
              <input type="hidden" name="kind" value="group"/>
              <input type="hidden" name="id" value={group.id}/>
              <input type="hidden" name="active" value={group.is_active?'false':'true'}/>
              <SubmitButton className={ghost}>{group.is_active?'Inativar':'Reativar'}</SubmitButton>
            </form>}
          </div>

          <form action={saveCommissionGroupConfiguration} className="mt-4">
            <input type="hidden" name="return_to" value="/app/comercial/grupos"/>
            <input type="hidden" name="group_id" value={group.id}/>
            <label className="text-xs text-slate-400">Nome do grupo
              <input required name="name" defaultValue={group.name} maxLength={80} className={field+' mt-1 block w-full'} disabled={!canEdit}/>
            </label>
            <div className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              {(components.data??[]).map(c=>{
                const value=limitMap.get(group.id+'|'+c.id)
                return <label key={c.id} className="rounded-xl border border-slate-800 p-3 text-xs text-slate-400">
                  {c.name} — máximo do recebido (%)
                  <input required name={'component_'+c.id} inputMode="decimal" defaultValue={value??''} placeholder={value===undefined?'Definir 0 a 100':'0 a 100'} className={field+' mt-2 w-full'} disabled={!canEdit}/>
                  {c.tech_key==='deferred'&&<span className="mt-2 block text-[11px] text-slate-500">Use 0 se este grupo não recebe Diferido.</span>}
                </label>
              })}
            </div>
            {canEdit&&<SubmitButton className={btn+' mt-4'}>{hasConfig?'Salvar configuração':'Configurar grupo'}</SubmitButton>}
          </form>
        </div>
      })}
    </div>
  </section>
}
