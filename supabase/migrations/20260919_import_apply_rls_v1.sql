-- PREPARED, NOT APPLIED (Human Gate: production RLS change). Found by the rollback-only E2E.
-- 1. import_applied_decisions has NO INSERT policy, so apply_approved_import_match (SECURITY INVOKER) fails with
--    "new row violates row-level security policy" for every real user: approved decisions could never be applied and no
--    financial fact could ever be published from an import. Add an INSERT policy for supervisor+ (same role the RPC requires).
-- 2. proposal_external_identities allowed INSERT for every member: an agent could bind (institution, external number) to any
--    proposal of the tenant and steer later imports to an 'exact' match. Only supervisor+ (the apply RPC's role) may write it.
-- Known debt (not changed): product_table_external_identities inserts require manager+, while the apply RPC admits supervisors,
-- so a supervisor cannot apply table-only matches (fails closed).
create policy import_applied_decisions_insert_supervisor_plus on public.import_applied_decisions
 for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

drop policy if exists proposal_external_identities_insert_member on public.proposal_external_identities;
create policy proposal_external_identities_insert_supervisor_plus on public.proposal_external_identities
 for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
