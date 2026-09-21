import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createAdminClient } from '@/lib/supabaseAdmin'
import { createCommissionGroup } from '../../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'

export default async function NewCommissionGroupPage(){
  const {membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return <section><p>Sem permissão.</p></section>
  const admin=createAdminClient()
  const components=await admin.from('commission_component_types').select('id,name,tech_key,sort_order').eq('is_active',true).order('sort_order').order('name')

  if(components.error||!(components.data??[]).length)return <section><p>Componentes de comissão indisponíveis.</p></section>

  return <section className="space-y-5">
    <div>
      <Link href="/app/comercial/grupos" className="text-sm text-slate-400 underline">← Voltar aos grupos de comissão</Link>
      <h1 className="mt-3 text-3xl font-semibold">Cadastrar grupo de comissão</h1>
      <p className="mt-2 text-sm text-slate-400">Cadastre o nome e a configuração completa de repasse em uma única etapa.</p>
    </div>

    <form action={createCommissionGroup} className={card}>
      <input type="hidden" name="return_to" value="/app/comercial/grupos"/>
      <label className="text-sm font-medium">Nome do grupo
        <input required name="name" maxLength={80} placeholder="Ex.: Balcão, Corretores, Parceiros, Subestabelecido" className={field+' mt-2 block w-full'}/>
      </label>

      <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {(components.data??[]).map(c=><label key={c.id} className="rounded-xl border border-slate-800 p-3 text-xs text-slate-400">
          {c.name} — máximo do recebido (%)
          <input required name={'component_'+c.id} inputMode="decimal" placeholder="0 a 100" className={field+' mt-2 w-full'}/>
          {c.tech_key==='deferred'&&<span className="mt-2 block text-[11px] text-slate-500">Use 0 se este grupo não recebe Diferido.</span>}
        </label>)}
      </div>

      <p className="mt-4 text-xs text-slate-500">100% = pode usar tudo o que a empresa recebeu naquele componente. 0% = não repassa.</p>
      <SubmitButton className={btn+' mt-4'}>Cadastrar grupo</SubmitButton>
    </form>
  </section>
}
