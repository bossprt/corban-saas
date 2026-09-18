import { requireAppContext } from '@/lib/appContext'

export default async function NetworkPage() {
  const { supabase } = await requireAppContext()
  const [entities, relationships, channels, splits] = await Promise.all([
    supabase.from('commercial_entities').select('id,legal_name,trade_name,tax_id,entity_kind,is_internal,is_active').order('legal_name'),
    supabase.from('commercial_relationships').select('id,relationship_role,effective_from,effective_until,is_active,upstream_entity_id,downstream_entity_id,bank_id').order('created_at',{ascending:false}),
    supabase.from('commercial_channels').select('id,name,external_partner_code,is_active,bank_id,relationship_id,payer_entity_id').order('name'),
    supabase.from('network_split_rule_versions').select('id,relationship_id,component_type,downstream_share,upstream_share,payment_flow,status,effective_from,effective_until').order('created_at',{ascending:false}),
  ])

  return <section>
    <h1 className="text-3xl font-semibold">Rede comercial</h1>
    <p className="mt-2 text-sm text-slate-400">Mapa de Masters, Subs, parceiros, canais e regras de participação econômica. O papel pertence à relação, não à empresa.</p>

    <div className="mt-6 grid gap-4 md:grid-cols-4">
      {[['Entidades',entities.data?.length??0],['Relações',relationships.data?.length??0],['Canais',channels.data?.length??0],['Regras de split',splits.data?.length??0]].map(([label,value])=>
        <div key={String(label)} className="rounded-xl border border-slate-800 bg-slate-900 p-5"><div className="text-sm text-slate-400">{label}</div><div className="mt-2 text-3xl font-semibold">{value}</div></div>
      )}
    </div>

    <div className="mt-8 rounded-xl border border-slate-800 bg-slate-900 p-5">
      <h2 className="text-lg font-semibold">Entidades cadastradas</h2>
      {!entities.data?.length ? <p className="mt-3 text-sm text-amber-300">Nenhuma entidade comercial cadastrada. O sistema não cria Masters, Subs ou parceiros por suposição.</p> :
      <div className="mt-4 space-y-2">{entities.data.map(e=><div key={e.id} className="rounded-lg border border-slate-800 p-3 text-sm"><strong>{e.trade_name||e.legal_name}</strong><span className="ml-3 text-slate-400">{e.entity_kind}</span>{e.tax_id&&<span className="ml-3 text-slate-500">{e.tax_id}</span>}</div>)}</div>}
    </div>

    <div className="mt-6 rounded-xl border border-slate-800 bg-slate-900 p-5 text-sm text-slate-300">
      Uma mesma tabela bancária poderá ter vários canais concorrentes. Cada proposta preservará o canal escolhido, produtor, pagador e versões das regras financeiras usadas.
    </div>
  </section>
}
