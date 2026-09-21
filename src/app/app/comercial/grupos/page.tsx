import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { setActive } from '../actions'

const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export default async function CommissionGroupsPage(){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')
  const admin=createAdminClient()

  const [groups,components,limits]=await Promise.all([
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    admin.from('commission_component_types').select('id,name,sort_order,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('commission_group_component_limits').select('group_id,component_type_id,max_received_share_pct'),
  ])

  if(components.error||!(components.data??[]).length){
    return <section className="space-y-4">
      <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>
      <h1 className="text-3xl font-semibold">Grupos de comissão</h1>
      <div className="rounded-xl border border-red-500/30 bg-red-500/5 p-4 text-sm text-red-200">Não foi possível carregar os componentes de comissão.</div>
    </section>
  }

  const limitMap=new Map((limits.data??[]).map(x=>[x.group_id+'|'+x.component_type_id,String(x.max_received_share_pct)]))
  const configuredCount=new Map<string,number>()
  for(const row of limits.data??[])configuredCount.set(row.group_id,(configuredCount.get(row.group_id)??0)+1)
  const totalComponents=(components.data??[]).length

  return <section>
    <Link href="/app/cadastros" className="text-sm text-slate-400 underline">← Voltar aos Cadastros</Link>

    <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h1 className="text-3xl font-semibold">Grupos de comissão</h1>
        <p className="mt-2 max-w-4xl text-sm text-slate-400">Consulte os grupos já cadastrados. Cadastre ou edite um grupo em uma única ficha.</p>
      </div>
      {canEdit&&<Link href="/app/comercial/grupos/novo" className={btn}>Cadastrar grupo</Link>}
    </div>

    <div className="mt-5 overflow-hidden rounded-2xl border border-slate-800">
      {!(groups.data??[]).length
        ? <div className={card}><p className="text-sm text-slate-400">Nenhum grupo de comissão cadastrado.</p></div>
        : <div className="divide-y divide-slate-800">
            {(groups.data??[]).map(group=>{
              const count=configuredCount.get(group.id)??0
              const configured=count===totalComponents
              return <div key={group.id} className="bg-slate-900 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-semibold">{group.name}</h2>
                      <span className={'text-xs '+(group.is_active?'text-emerald-300':'text-slate-500')}>{group.is_active?'Ativo':'Inativo'}</span>
                      <span className={'text-xs '+(configured?'text-sky-300':'text-amber-300')}>{configured?'Configurado':'Configuração pendente'}</span>
                    </div>
                    {configured
                      ? <div className="mt-3 flex flex-wrap gap-2">{(components.data??[]).map(c=><span key={c.id} className="rounded-lg border border-slate-800 bg-slate-950/60 px-2 py-1 text-xs text-slate-400">{c.name}: {limitMap.get(group.id+'|'+c.id)??'—'}%</span>)}</div>
                      : <p className="mt-2 text-xs text-slate-500">Defina os percentuais dos {totalComponents} componentes.</p>}
                  </div>

                  <div className="flex flex-wrap gap-2">
                    {canEdit&&<Link href={'/app/comercial/grupos/'+group.id} className={ghost}>Editar</Link>}
                    {canEdit&&<form action={setActive}>
                      <input type="hidden" name="return_to" value="/app/comercial/grupos"/>
                      <input type="hidden" name="kind" value="group"/>
                      <input type="hidden" name="id" value={group.id}/>
                      <input type="hidden" name="active" value={group.is_active?'false':'true'}/>
                      <SubmitButton className={ghost}>{group.is_active?'Inativar':'Reativar'}</SubmitButton>
                    </form>}
                  </div>
                </div>
              </div>
            })}
          </div>}
    </div>
  </section>
}
