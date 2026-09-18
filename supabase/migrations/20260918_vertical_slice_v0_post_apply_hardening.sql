-- Corban OS V0 post-apply hardening: exposed global catalog + FK coverage.
alter table public.banks enable row level security;
alter table public.providers enable row level security;
alter table public.agreements enable row level security;
alter table public.products enable row level security;
alter table public.modalities enable row level security;
alter table public.document_types enable row level security;

revoke all on table public.banks, public.providers, public.agreements, public.products, public.modalities, public.document_types from anon;
grant select on table public.banks, public.providers, public.agreements, public.products, public.modalities, public.document_types to authenticated;
grant select, insert, update, delete on table public.banks, public.providers, public.agreements, public.products, public.modalities, public.document_types to service_role;

create policy banks_authenticated_read on public.banks for select to authenticated using (true);
create policy providers_authenticated_read on public.providers for select to authenticated using (true);
create policy agreements_authenticated_read on public.agreements for select to authenticated using (true);
create policy products_authenticated_read on public.products for select to authenticated using (true);
create policy modalities_authenticated_read on public.modalities for select to authenticated using (true);
create policy document_types_authenticated_read on public.document_types for select to authenticated using (true);

create index if not exists document_checklist_items_org_template_idx on public.document_checklist_items (organization_id, template_id);
create index if not exists document_checklist_templates_org_route_idx on public.document_checklist_templates (organization_id, route_id);
create index if not exists operational_cases_org_stage_state_idx on public.operational_cases (organization_id, current_stage_id, canonical_state);
create index if not exists product_table_versions_org_table_idx on public.product_table_versions (organization_id, product_table_id);
create index if not exists proposal_document_links_org_requirement_idx on public.proposal_document_links (organization_id, requirement_id);
create index if not exists proposals_v2_simulation_snapshot_idx on public.proposals_v2 (organization_id, simulation_id, customer_id, product_table_version_id);
