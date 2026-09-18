-- CORBAN OS V2 — Financial + commercial FK performance patch
-- Corrective indexes and RLS init-plan optimization inside already-authorized scopes.
create index if not exists channel_commission_rules_product_table_idx on public.channel_commission_rule_versions(product_table_id);
create index if not exists commercial_channels_bank_idx on public.commercial_channels(bank_id);
create index if not exists commercial_relationships_downstream_idx on public.commercial_relationships(downstream_entity_id);
create index if not exists commercial_relationships_upstream_idx on public.commercial_relationships(upstream_entity_id);
create index if not exists commission_components_org_idx on public.commission_rule_components(organization_id);
create index if not exists financial_events_proposal_idx on public.financial_events(proposal_id);
create index if not exists financial_evidence_org_idx on public.financial_evidence_links(organization_id);
create index if not exists network_split_org_idx on public.network_split_rule_versions(organization_id);
create index if not exists network_split_product_table_idx on public.network_split_rule_versions(product_table_id);
create index if not exists product_table_external_product_idx on public.product_table_external_identities(product_table_id);
drop policy if exists financial_events_insert_supervisor on public.financial_events;
create policy financial_events_insert_supervisor on public.financial_events for insert to authenticated
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']) and created_by=(select auth.uid()));
