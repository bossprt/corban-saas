-- PREPARED, NOT APPLIED (Human Gate: production RLS change that reduces read access for role `agent`).
-- Finding: SELECT policies on financial and commission-rule tables allow EVERY active member (including `agent`) to read
-- commission economics directly through the API. The app hides these screens for agents, but hiding a React component
-- is not access control. Restrict SELECT to supervisor+ (admin, manager, supervisor) on the tables that are purely
-- financial or hold commission rules:
--   financial_events, financial_evidence_links, financial_reconciliation_cases,
--   channel_commission_rule_versions, commission_rule_components, network_split_rule_versions,
--   proposal_commercial_component_snapshots.
-- NOT changed here (needs column-level views, tracked as debt): proposal_commercial_snapshots (route + rule refs + jsonb
-- snapshot used by agents to see the route) and import_normalized_rows (commission_* columns next to identity columns).
-- Write paths are unchanged. Depends on public.has_active_organization_role being executable by authenticated.
do $$
declare t text;
begin
 foreach t in array array['financial_events','financial_evidence_links','financial_reconciliation_cases','channel_commission_rule_versions','commission_rule_components','network_split_rule_versions'] loop
  execute format('drop policy if exists %I on public.%I',t||'_select_member',t);
  execute format($p$create policy %I on public.%I for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))$p$,t||'_select_supervisor_plus',t);
 end loop;
 drop policy if exists proposal_commercial_component_snapshots_select on public.proposal_commercial_component_snapshots;
 create policy proposal_commercial_component_snapshots_select_supervisor_plus on public.proposal_commercial_component_snapshots
  for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
end $$;
