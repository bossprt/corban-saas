-- PREPARED, NOT APPLIED. Forward-only performance cleanup after catalog_publish_v1.
-- Merges the two permissive UPDATE policies on each catalog table into one logically equivalent policy.
-- Guard triggers and governed publication RPCs remain the authority for status transitions.
-- No grants, functions, triggers or data are changed.

drop policy product_table_versions_update_draft_manager on public.product_table_versions;
drop policy product_table_versions_supersede_manager on public.product_table_versions;
create policy product_table_versions_update_manager on public.product_table_versions
for update to authenticated
using (
  status in ('draft','published')
  and public.has_active_organization_role(organization_id,array['admin','manager'])
)
with check (
  status in ('draft','published','superseded')
  and public.has_active_organization_role(organization_id,array['admin','manager'])
);

drop policy document_checklist_templates_update_draft_supervisor on public.document_checklist_templates;
drop policy document_checklist_templates_supersede_supervisor on public.document_checklist_templates;
create policy document_checklist_templates_update_supervisor on public.document_checklist_templates
for update to authenticated
using (
  status in ('draft','published')
  and public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
)
with check (
  status in ('draft','published','superseded')
  and public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
);
