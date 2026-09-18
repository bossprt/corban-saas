import { requireAppContext } from '@/lib/appContext'
import { createCommercialChannel, createCommercialEntity, createCommercialRelationship, publishCommissionRule, publishSplitRule } from './actions'

export default async function NetworkPage() {
 const {supabase,membership}=await requireAppContext()
 const [entities,relationships,channels,splits,banks,tables,rules]=await Promise.all([
  supabase.from('commercial_entities').select('id,legal_name,trade_name,tax_id,entity_kind,is_internal,is_active').order('legal_name'),
  supabase.from('commercial_relationships').select('id,relationship_role,effective_from,effective_until,is_active,upstream_entity_id,downstream_entity_id,bank_id').order('created_at',{ascending:false}),
  supabase.from('commercial_channels').select('id,name,external_partner_code,is_active,bank_id,relationship_id,payer_entity_id').order('name'),
  supabase.from('network_split_rule_versions').select('id,relationship_id,component_type,downstream_share,upstream_share,payment_flow,status,effective_from,effective_until').order('created_at',{ascending:false}),
  supabase.from('banks').select('id,name,code').eq('is_active',true).order('name'),
  supabase.from('product_tables').select('id,code,name').eq('status','active').order('name'),
  supabase.from('channel_commission_rule_versions').select('id,status,version,channel_id,product_table_id,effective_from').order('created_at',{ascending:false})
 ])
 const canManage=['admin','manager'].includes(membership.role)
 const entityName=new Map((entities.data??[]).map(e=>[e.id,e.trade_name||e.legal_name]))
 const bankName=new Map((banks.data??[]).map(b=>[b.id,b.name]))
 const activeSplits=(splits.data??[]).filter(x=>x.status==='published').length
 const ruleCount=rules.data?.length??0

 return <section>
  <h1 className="text-3xl font-semibold">Rede comercial</h1>
  <p className="mt-2 text-sm text-slate-400">Masters, Subs e parceiros são papéis de uma relação. A mesma empresa pode participar de vários canais para o mesmo banco.</p>

  <div className="mt-6 grid gap-4 md:grid-cols-4">
   {[['Entidades',entities.data?.length??0],['Relações',relationships.data?.length??0],['Canais',channels.data?.length??0],['Regras de split',splits.data?.length??0]].map(([label,value])=>
    <div key={String(label)} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{label}</div><div className="mt-2 text-3xl font-semibold">{value}</div></div>)}
  </div>

  {canManage&&<div className="mt-8 grid gap-5 xl:grid-cols-3">
   <form action={createCommercialEntity} className="rounded-xl border border-slate-800 bg-slate-900 p-5 space-y-3">
    <h2 className="font-semibold">Nova entidade</h2>
    <input name="legal_name" required placeholder="Razão social / nome" className="w-full rounded bg-slate-950 p-2"/>
    <input name="trade_name" placeholder="Nome fantasia" className="w-full rounded bg-slate-950 p-2"/>
    <input name="tax_id" placeholder="CNPJ/CPF (opcional)" className="w-full rounded bg-slate-950 p-2"/>
    <select name="entity_kind" className="w-full rounded bg-slate-950 p-2"><option value="correspondent">Correspondente</option><option value="promotora">Promotora</option><option value="partner">Parceiro</option><option value="broker">Corretor</option><option value="indicator">Indicador</option><option value="bank">Banco</option><option value="association">Associação</option><option value="other">Outro</option></select>
    <label className="flex gap-2 text-sm"><input type="checkbox" name="is_internal"/> Entidade do próprio tenant</label>
    <button className="rounded bg-white px-3 py-2 text-sm font-medium text-slate-950">Cadastrar entidade</button>
   </form>

   <form action={createCommercialRelationship} className="rounded-xl border border-slate-800 bg-slate-900 p-5 space-y-3">
    <h2 className="font-semibold">Nova relação</h2>
    <select name="upstream_entity_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Entidade acima</option>{entities.data?.map(e=><option key={e.id} value={e.id}>{e.trade_name||e.legal_name}</option>)}</select>
    <select name="downstream_entity_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Entidade abaixo</option>{entities.data?.map(e=><option key={e.id} value={e.id}>{e.trade_name||e.legal_name}</option>)}</select>
    <select name="relationship_role" className="w-full rounded bg-slate-950 p-2"><option value="master">Master</option><option value="subestablished">Subestabelecido</option><option value="partner">Parceiro</option><option value="broker">Corretor</option><option value="indicator">Indicador</option><option value="other">Outro</option></select>
    <select name="bank_id" className="w-full rounded bg-slate-950 p-2"><option value="">Todos/sem banco específico</option>{banks.data?.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select>
    <input name="effective_from" type="date" required defaultValue={new Date().toISOString().slice(0,10)} className="w-full rounded bg-slate-950 p-2"/>
    <button disabled={!entities.data?.length} className="rounded bg-white px-3 py-2 text-sm font-medium text-slate-950 disabled:opacity-40">Cadastrar relação</button>
   </form>

   <form action={createCommercialChannel} className="rounded-xl border border-slate-800 bg-slate-900 p-5 space-y-3">
    <h2 className="font-semibold">Novo canal</h2>
    <input name="name" required placeholder="Ex.: Daycoval via LEV" className="w-full rounded bg-slate-950 p-2"/>
    <select name="bank_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Banco</option>{banks.data?.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select>
    <select name="relationship_id" className="w-full rounded bg-slate-950 p-2"><option value="">Sem relação vinculada</option>{relationships.data?.map(r=><option key={r.id} value={r.id}>{entityName.get(r.upstream_entity_id)} → {entityName.get(r.downstream_entity_id)} ({r.relationship_role})</option>)}</select>
    <select name="payer_entity_id" className="w-full rounded bg-slate-950 p-2"><option value="">Pagador não definido</option>{entities.data?.map(e=><option key={e.id} value={e.id}>{e.trade_name||e.legal_name}</option>)}</select>
    <input name="external_partner_code" placeholder="Código externo do canal" className="w-full rounded bg-slate-950 p-2"/>
    <button disabled={!banks.data?.length} className="rounded bg-white px-3 py-2 text-sm font-medium text-slate-950 disabled:opacity-40">Cadastrar canal</button>
   </form>
  </div>}

{canManage&&<div className="mt-8 grid gap-5 xl:grid-cols-2">
 <form action={publishCommissionRule} className="rounded-xl border border-slate-800 bg-slate-900 p-5 space-y-3"><h2 className="font-semibold">Publicar comissão</h2><select name="channel_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Canal</option>{channels.data?.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><select name="product_table_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Tabela</option>{tables.data?.map(x=><option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}</select><select name="component_type" className="w-full rounded bg-slate-950 p-2"><option value="upfront">À vista</option><option value="deferred">Diferido</option><option value="deferred_anticipation">Antecipação diferido</option><option value="campaign_bonus">Bônus campanha</option><option value="volume_bonus">Bônus volume</option><option value="fixed">Fixo</option></select><input name="percentage" type="number" step="0.0001" min="0" placeholder="% comissão" className="w-full rounded bg-slate-950 p-2"/><input name="fixed_amount" type="number" step="0.01" min="0" placeholder="Valor fixo (alternativo)" className="w-full rounded bg-slate-950 p-2"/><input name="anticipation_factor" type="number" step="0.0001" min="0" placeholder="Fator antecipação (ex.: 0,22)" className="w-full rounded bg-slate-950 p-2"/><input name="calculation_base" defaultValue="proposal_amount" className="w-full rounded bg-slate-950 p-2"/><input name="effective_from" type="date" required defaultValue={new Date().toISOString().slice(0,10)} className="w-full rounded bg-slate-950 p-2"/><button className="rounded bg-white px-3 py-2 text-sm font-medium text-slate-950">Publicar versão imutável</button></form>
 <form action={publishSplitRule} className="rounded-xl border border-slate-800 bg-slate-900 p-5 space-y-3"><h2 className="font-semibold">Publicar split/repasse</h2><select name="relationship_id" required className="w-full rounded bg-slate-950 p-2"><option value="">Relação</option>{relationships.data?.map(r=><option key={r.id} value={r.id}>{entityName.get(r.upstream_entity_id)} → {entityName.get(r.downstream_entity_id)}</option>)}</select><select name="bank_id" className="w-full rounded bg-slate-950 p-2"><option value="">Banco opcional</option>{banks.data?.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select><select name="product_table_id" className="w-full rounded bg-slate-950 p-2"><option value="">Todas as tabelas</option>{tables.data?.map(x=><option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}</select><select name="component_type" className="w-full rounded bg-slate-950 p-2"><option value="">Todos componentes</option><option value="upfront">À vista</option><option value="deferred">Diferido</option><option value="deferred_anticipation">Antecipação diferido</option><option value="campaign_bonus">Bônus campanha</option></select><input name="downstream_percentage" required type="number" min="0" max="100" step="0.01" placeholder="% downstream" className="w-full rounded bg-slate-950 p-2"/><select name="payment_flow" className="w-full rounded bg-slate-950 p-2"><option value="direct_by_payer">Pago direto pelo pagador</option><option value="through_upstream">Via upstream</option><option value="through_downstream">Via downstream</option><option value="other">Outro</option></select><input name="effective_from" type="date" required defaultValue={new Date().toISOString().slice(0,10)} className="w-full rounded bg-slate-950 p-2"/><button className="rounded bg-white px-3 py-2 text-sm font-medium text-slate-950">Publicar split imutável</button></form>
 </div>}
 <div className="mt-8 rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="font-semibold">Regras comerciais publicadas</h2><p className="mt-2 text-sm text-slate-400">{ruleCount} versões de comissão · {activeSplits} splits publicados</p></div>
  <div className="mt-8 grid gap-5 lg:grid-cols-2">
   <div className="rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="text-lg font-semibold">Entidades</h2>
    {!entities.data?.length?<p className="mt-3 text-sm text-amber-300">Nenhuma entidade cadastrada.</p>:<div className="mt-4 space-y-2">{entities.data.map(e=><div key={e.id} className="rounded-lg border border-slate-800 p-3 text-sm"><strong>{e.trade_name||e.legal_name}</strong><span className="ml-3 text-slate-400">{e.entity_kind}</span></div>)}</div>}
   </div>
   <div className="rounded-xl border border-slate-800 bg-slate-900 p-5"><h2 className="text-lg font-semibold">Canais</h2>
    {!channels.data?.length?<p className="mt-3 text-sm text-slate-400">Nenhum canal cadastrado.</p>:<div className="mt-4 space-y-2">{channels.data.map(c=><div key={c.id} className="rounded-lg border border-slate-800 p-3 text-sm"><strong>{c.name}</strong><span className="ml-3 text-slate-400">{bankName.get(c.bank_id)||'Banco'}</span>{c.external_partner_code&&<span className="ml-3 text-slate-500">{c.external_partner_code}</span>}</div>)}</div>}
   </div>
  </div>
 </section>
}
