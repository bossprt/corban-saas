import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { freezeCommercialRoute } from './actions'

export async function CommercialRouteFreezeCard({ proposalId }: { proposalId: string }) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'supervisor')) return null

  const { data: proposal } = await supabase
    .from('proposals_v2')
    .select('id,status,product_table_version_id')
    .eq('id', proposalId)
    .maybeSingle()

  if (!proposal || proposal.status !== 'draft') return null

  const { data: existingRoute } = await supabase
    .rpc('get_commercial_route', { p_proposal_id: proposalId })
    .maybeSingle()
  if (existingRoute) return null

  const { data: tableVersion } = await supabase
    .from('product_table_versions')
    .select('product_table_id')
    .eq('id', proposal.product_table_version_id)
    .maybeSingle()

  if (!tableVersion?.product_table_id) return null

  const [{ data: rules }, { data: producers }] = await Promise.all([
    supabase
      .from('channel_commission_rule_versions')
      .select('id,channel_id,version,operation_type,effective_from,effective_until')
      .eq('product_table_id', tableVersion.product_table_id)
      .eq('status', 'published')
      .order('version', { ascending: false }),
    supabase
      .from('commercial_entities')
      .select('id,legal_name,trade_name,entity_kind')
      .eq('is_active', true)
      .order('trade_name'),
  ])

  const now = new Date().toISOString()
  const activeRules = (rules ?? []).filter(r =>
    (!r.effective_from || r.effective_from <= now) &&
    (!r.effective_until || r.effective_until > now)
  )

  return <div className="mt-6 rounded-2xl border border-slate-800 bg-slate-900 p-5">
    <h2 className="font-semibold">Congelar rota comercial</h2>
    <p className="mt-1 text-xs text-slate-500">Escolha uma regra publicada e vigente. O canal é derivado da própria regra para evitar combinações inválidas.</p>
    {!activeRules.length
      ? <p className="mt-3 text-sm text-amber-200">Não existe regra comercial publicada e vigente para a tabela desta proposta.</p>
      : <form action={freezeCommercialRoute} className="mt-4 grid gap-3">
          <input type="hidden" name="proposal_id" value={proposalId}/>
          <label className="text-xs text-slate-400">
            Regra comercial
            <select required name="commission_rule_version_id" defaultValue="" className="field mt-1 w-full">
              <option value="" disabled>Selecione a regra vigente</option>
              {activeRules.map(r => <option key={r.id} value={r.id}>v{r.version}{r.operation_type ? ' · ' + r.operation_type : ''} · canal {r.channel_id.slice(0, 8)}</option>)}
            </select>
          </label>
          <label className="text-xs text-slate-400">
            Produtor (opcional)
            <select name="producer_entity_id" defaultValue="" className="field mt-1 w-full">
              <option value="">Sem produtor específico</option>
              {(producers ?? []).map(e => <option key={e.id} value={e.id}>{e.trade_name ?? e.legal_name} · {e.entity_kind}</option>)}
            </select>
          </label>
          <button className="justify-self-start rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950">Congelar rota comercial</button>
        </form>}
  </div>
}
