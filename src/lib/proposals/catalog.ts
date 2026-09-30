import type { requireAppContext } from '@/lib/appContext'
import { effectiveContractTypes } from '@/lib/contract-types'

type Supa = Awaited<ReturnType<typeof requireAppContext>>['supabase']

// What a proposal form offers, in the order the operator chooses (owner request 29/09/2026, ADR-0049):
// Banco (the bank, or "Promotora - Banco" when sold through a partner promoter) -> Tipo de contrato -> Tabela.
export type CatalogOrigin = { key: string; label: string }
export type CatalogType = { id: string; name: string }
export type CatalogTable = { versionId: string; label: string; origin: string; types: string[] }
export type ProposalCatalog = { origins: CatalogOrigin[]; types: CatalogType[]; tables: CatalogTable[] }

export const originKey = (bankId: string, providerId: string | null) => `${bankId}:${providerId ?? 'own'}`

type Row = { version_id: string; version: number; table_name: string; bank_id: string; bank_name: string; provider_id: string | null; provider_name: string | null; contract_type_id: string | null; kept: boolean }

// The vigência in force now of each active table (public.proposal_catalog: no rates, so brokers can use it too).
// `keep` adds a contract's own older vigência, so the contract file still shows what it was made with.
export async function loadProposalCatalog(supabase: Supa, organizationId: string, keep?: string | null): Promise<ProposalCatalog> {
  const [{ data }, { data: typeRows }, { data: settings }] = await Promise.all([
    supabase.rpc('proposal_catalog', { p_org: organizationId, p_keep: keep ?? null }),
    supabase.from('contract_types').select('id,name,tech_key,is_active,organization_id').order('sort_order').order('name'),
    supabase.from('organization_contract_type_settings').select('contract_type_id,is_enabled,use_in_pipeline,use_in_commission'),
  ])
  // Types switched off in the company's settings are not offered (same rule as the simulation).
  const enabled = effectiveContractTypes((typeRows ?? []) as { id: string; name: string; tech_key: string; is_active: boolean; organization_id: string | null }[],
    (settings ?? []) as { contract_type_id: string; is_enabled: boolean; use_in_pipeline: boolean; use_in_commission: boolean }[], 'general')
  const enabledIds = new Set(enabled.map(t => t.id))
  const rows = (data ?? []) as Row[]
  const origins = new Map<string, string>()
  const tables = new Map<string, CatalogTable>()
  for (const r of rows) {
    const key = originKey(r.bank_id, r.provider_id)
    origins.set(key, r.provider_id ? `${r.provider_name ?? 'Promotora'} - ${r.bank_name}` : r.bank_name)
    const t = tables.get(r.version_id) ?? { versionId: r.version_id, label: `${r.table_name} (v${r.version}${r.kept ? ', do contrato' : ''})`, origin: key, types: [] }
    if (r.contract_type_id && (enabledIds.has(r.contract_type_id) || r.kept) && !t.types.includes(r.contract_type_id)) t.types.push(r.contract_type_id)
    tables.set(r.version_id, t)
  }
  const usedTypes = new Set([...tables.values()].flatMap(t => t.types))
  return {
    origins: [...origins].map(([key, label]) => ({ key, label })).sort((a, b) => a.label.localeCompare(b.label, 'pt-BR')),
    types: (typeRows ?? []).filter(t => usedTypes.has(t.id)).map(t => ({ id: t.id, name: t.name })),
    tables: [...tables.values()].sort((a, b) => a.label.localeCompare(b.label, 'pt-BR')),
  }
}
