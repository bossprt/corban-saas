import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader, Badge } from '@/components/ui'
import { createContractType, saveContractTypeSettings, updateOwnContractType } from './actions'

const btn='inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost='h-9 rounded-[10px] border border-line bg-surface px-3 text-xs hover:bg-surface-muted'

export default async function ContractTypesPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><p className="text-sm text-muted">Sem permissão.</p></section>
 const canEdit=atLeast(membership.role,'manager')
 const [types,settings]=await Promise.all([
  supabase.from('contract_types').select('id,name,tech_key,is_active,sort_order,organization_id').order('sort_order').order('name'),
  supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission')
 ])
 const setting=new Map((settings.data??[]).map(x=>[x.contract_type_id,x]))
 return <section>
  <Link href="/app/cadastros" className="text-sm text-brand hover:underline">← Cadastros</Link>
  <PageHeader title="Tipos de Contrato" description="Tipos globais como Novo, Refinanciamento, Portabilidade e Refin/Portabilidade podem ser habilitados conforme a operação. Sua empresa também pode criar tipos próprios." />

  {canEdit&&<Card className="p-5"><form action={createContractType} className="flex flex-wrap gap-2">
   <input required name="name" maxLength={80} placeholder="Novo tipo de contrato" className="field min-w-64 flex-1"/>
   <SubmitButton className={btn}>Cadastrar tipo</SubmitButton>
  </form></Card>}

  <div className="mt-5 space-y-3">{(types.data??[]).map(t=>{
   const s=setting.get(t.id)
   const global=t.organization_id===null
   return <Card key={t.id} className="p-5">
    <div className="flex flex-wrap items-start justify-between gap-3">
     <div><h2 className="font-semibold text-ink">{t.name}</h2><p className="mt-1 text-xs text-muted">{global?'Padrão da plataforma':'Criado pela sua empresa'} · {t.is_active?'Ativo':'Inativo'}</p></div>
     {t.tech_key==='refin_portabilidade'&&<Badge tone="received">Refinanciamento da Portabilidade</Badge>}
    </div>
    <form action={saveContractTypeSettings} className="mt-4 flex flex-wrap items-center gap-5 text-sm">
     <input type="hidden" name="contract_type_id" value={t.id}/>
     <label className="text-ink-soft"><input type="checkbox" name="is_enabled" defaultChecked={s?.is_enabled??true} className="mr-2"/>Habilitado</label>
     <label className="text-ink-soft"><input type="checkbox" name="use_in_pipeline" defaultChecked={s?.use_in_pipeline??true} className="mr-2"/>Usar na esteira</label>
     <label className="text-ink-soft"><input type="checkbox" name="use_in_commission" defaultChecked={s?.use_in_commission??true} className="mr-2"/>Usar em comissão</label>
     {canEdit&&<SubmitButton className={ghost}>Salvar configuração</SubmitButton>}
    </form>
    {!global&&canEdit&&<details className="mt-3"><summary className="cursor-pointer text-xs text-brand underline">Editar tipo próprio</summary><form action={updateOwnContractType} className="mt-2 flex flex-wrap gap-2"><input type="hidden" name="id" value={t.id}/><input name="name" required defaultValue={t.name} className="field"/><select name="active" defaultValue={t.is_active?'true':'false'} className="field"><option value="true">Ativo</option><option value="false">Inativo</option></select><SubmitButton className={ghost}>Salvar</SubmitButton></form></details>}
   </Card>
  })}</div>
 </section>
}
