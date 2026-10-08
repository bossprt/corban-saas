import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { Card, PageHeader } from '@/components/ui'
import { FactorPriceImport } from './FactorPriceImport'
import { createFactorProfile, createManualFactor, importFactorFile, toggleFactorProfile } from './actions'

const btn='inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong'
const ghost='h-9 rounded-[10px] border border-line bg-surface px-3 text-xs hover:bg-surface-muted'
const MODE:Record<string,string>={daily:'Diário',fixed:'Fixo'}
const brDate=(d:string)=>d.split('-').reverse().join('/')

export default async function FactorsPage(){
 const {supabase,membership}=await requireAppContext()
 if(!atLeast(membership.role,'supervisor'))return <section><p className="text-sm text-muted">Sem permissão.</p></section>
 const canEdit=atLeast(membership.role,'manager')
 const [profiles,banks,agreements,tables,types,batches,entries]=await Promise.all([
  supabase.from('commercial_factor_profiles').select('id,name,org_bank_id,org_agreement_id,product_table_id,bank_table_code,contract_type_id,factor_mode,is_active').order('name'),
  supabase.from('organization_banks').select('id,name,is_active').order('name'),
  supabase.from('organization_agreements').select('id,name,is_active').order('name'),
  supabase.from('product_tables').select('id,name,status').order('name'),
  supabase.from('contract_types').select('id,name,is_active').order('sort_order'),
  supabase.from('commercial_factor_batches').select('id,profile_id,effective_date,revision,status,source_kind,source_note,published_at').eq('status','published').order('effective_date',{ascending:false}),
  supabase.from('commercial_factor_entries').select('batch_id,term_min,term_max,factor_value').order('term_min'),
 ])
 const names=(rows:{id:string;name:string}[]|null)=>new Map((rows??[]).map(x=>[x.id,x.name]))
 const bankN=names(banks.data),agrN=names(agreements.data),tableN=names(tables.data),typeN=names(types.data)
 // Today in Brasília: a daily profile counts only with a batch for today; a fixed one uses the last batch up to today.
 const today=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo'}).format(new Date())
 type Batch=typeof batches.data extends (infer T)[]|null?T:never
 const history=new Map<string,Batch[]>()
 for(const b of batches.data??[])history.set(b.profile_id,[...(history.get(b.profile_id)??[]),b])
 const current=(mode:string,list:Batch[])=>list.find(b=>mode==='daily'?String(b.effective_date)===today:String(b.effective_date)<=today)
 const entriesBy=new Map<string,(typeof entries.data extends (infer T)[]|null?T:never)[]>()
 for(const e of entries.data??[])entriesBy.set(e.batch_id,[...(entriesBy.get(e.batch_id)??[]),e])
 return <section>
  <Link href="/app/cadastros" className="text-sm text-brand hover:underline">← Cadastros</Link>
  <PageHeader title="Fatores" description="Parcela = valor × fator. Fator diário vale só na data dele. Fator fixo vale até a próxima publicação. O simulador mostra só tabelas com fator valendo." />

  {canEdit&&<Card className="p-5">
   <form action={createFactorProfile}>
   <h2 className="font-semibold text-ink">Criar perfil de fator</h2>
   <div className="mt-3 grid gap-2 md:grid-cols-3">
    <input required name="name" maxLength={120} placeholder="Ex.: Daycoval Governo AC Novo" className="field"/>
    <select required name="org_bank_id" defaultValue="" className="field"><option value="" disabled>Instituição</option>{(banks.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select required name="factor_mode" defaultValue="" className="field"><option value="" disabled>Regime</option><option value="daily">Fator diário</option><option value="fixed">Fator fixo</option></select>
    <select name="org_agreement_id" defaultValue="" className="field"><option value="">Todos os convênios</option>{(agreements.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="product_table_id" defaultValue="" className="field"><option value="">Todas as tabelas</option>{(tables.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select name="contract_type_id" defaultValue="" className="field"><option value="">Todos os tipos de contrato</option>{(types.data??[]).filter(x=>x.is_active).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
   </div>
   <SubmitButton className={`${btn} mt-3`}>Criar perfil</SubmitButton>
   </form>
  </Card>}
  {canEdit&&<FactorPriceImport banks={(banks.data??[]).filter(x=>x.is_active)} agreements={(agreements.data??[]).filter(x=>x.is_active)}/>}

  <div className="mt-5 space-y-3">{!(profiles.data??[]).length?<Card className="p-5"><p className="text-sm text-muted">Nenhum perfil de fator cadastrado.</p></Card>:(profiles.data??[]).map(p=>{
   const list=history.get(p.id)??[], b=current(p.factor_mode,list), es=b?entriesBy.get(b.id)??[]:[]
   const future=list.filter(x=>String(x.effective_date)>today)
   return <Card key={p.id} className={`p-5 ${p.is_active?'':'opacity-60'}`}>
    <div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="font-semibold text-ink">{p.name}</h2><p className="mt-1 text-xs text-muted">{MODE[p.factor_mode]??p.factor_mode} · {bankN.get(p.org_bank_id)??'Instituição'}{p.org_agreement_id?` · ${agrN.get(p.org_agreement_id)??'Convênio'}`:''}{p.product_table_id?` · ${tableN.get(p.product_table_id)??'Tabela'}`:''}{p.bank_table_code?` · tabela do banco ${p.bank_table_code} (todas as promotoras)`:''}{p.contract_type_id?` · ${typeN.get(p.contract_type_id)??'Tipo'}`:''}</p></div><div className="flex flex-wrap items-center gap-2">
     {!p.is_active?<span className="rounded-full bg-surface-muted px-2 py-0.5 text-xs text-muted">Desativado: o simulador não usa</span>
      :b?<span className="rounded-full bg-brand-soft px-2 py-0.5 text-xs text-brand-strong">Valendo hoje: {p.factor_mode==='daily'?`fator de ${brDate(String(b.effective_date))}`:`desde ${brDate(String(b.effective_date))}`} · rev. {b.revision}</span>
      :<span className="rounded-full bg-red-50 px-2 py-0.5 text-xs font-medium text-red-700">{p.factor_mode==='daily'?'Sem fator para hoje: o simulador não mostra estas tabelas':'Sem fator publicado'}</span>}
     {canEdit&&<form action={toggleFactorProfile}><input type="hidden" name="profile_id" value={p.id}/><input type="hidden" name="active" value={p.is_active?'false':'true'}/><SubmitButton className={ghost}>{p.is_active?'Desativar':'Ativar'}</SubmitButton></form>}
    </div></div>
    {future.length>0&&<p className="mt-2 text-xs text-muted">Agendado: {future.map(x=>brDate(String(x.effective_date))).join(', ')}</p>}
    {b&&<div className="mt-3 overflow-x-auto"><table className="w-full text-left text-xs"><thead className="text-muted"><tr><th className="py-2">Prazo</th><th>Fator</th><th>Origem</th></tr></thead><tbody>{es.map((e,i)=><tr key={i} className="border-t border-line"><td className="py-2 text-ink-soft">{e.term_min===e.term_max?`${e.term_min}x`:`${e.term_min}–${e.term_max}x`}</td><td className="text-ink-soft">{String(e.factor_value)}</td><td className="text-ink-soft">{b.source_kind}{b.source_note?` · ${b.source_note}`:''}</td></tr>)}</tbody></table></div>}
    {list.length>0&&<details className="mt-3 text-xs"><summary className="cursor-pointer text-muted">Histórico ({list.length})</summary><table className="mt-2 w-full text-left"><thead className="text-muted"><tr><th className="py-1">Vigência</th><th>Rev.</th><th>Fatores</th><th>Origem</th></tr></thead><tbody>{list.slice(0,30).map(x=><tr key={x.id} className="border-t border-line"><td className="py-1 text-ink-soft">{brDate(String(x.effective_date))}</td><td className="text-ink-soft">{x.revision}</td><td className="text-ink-soft">{(entriesBy.get(x.id)??[]).map(e=>`${e.term_min===e.term_max?e.term_min:`${e.term_min}–${e.term_max}`}x: ${e.factor_value}`).join(' · ')}</td><td className="text-ink-soft">{x.source_kind}{x.source_note?` · ${x.source_note}`:''}</td></tr>)}</tbody></table></details>}
    {canEdit&&p.is_active&&<div className="mt-4 grid gap-3 lg:grid-cols-2">
      <details className="rounded-[10px] border border-line p-4"><summary className="cursor-pointer font-medium text-ink">Cadastrar manualmente</summary><form action={createManualFactor} className="mt-3 grid gap-2 md:grid-cols-2"><input type="hidden" name="profile_id" value={p.id}/><input required type="date" name="effective_date" defaultValue={today} className="field"/><input required name="factor_value" inputMode="decimal" placeholder="Fator" className="field"/><input required name="term_min" inputMode="numeric" placeholder="Prazo inicial" className="field"/><input required name="term_max" inputMode="numeric" placeholder="Prazo final" className="field"/><SubmitButton className={ghost}>Publicar fator</SubmitButton></form></details>
      <details className="rounded-[10px] border border-line bg-brand-soft p-4"><summary className="cursor-pointer font-medium text-brand-strong">Importar fatores</summary><p className="mt-2 text-xs text-muted">Nesta primeira entrega: CSV ou XLSX com colunas Prazo Inicial, Prazo Final e Fator. PDF/XLS legado entra na próxima etapa do importador adaptativo.</p><form action={importFactorFile} className="mt-3 space-y-2"><input type="hidden" name="profile_id" value={p.id}/><input required type="date" name="effective_date" defaultValue={today} className="field w-full"/><input required type="file" name="file" accept=".csv,.xlsx,text/csv" className="block w-full text-xs"/><SubmitButton className={btn}>Importar e publicar</SubmitButton></form></details>
    </div>}
   </Card>
  })}</div>
 </section>
}
