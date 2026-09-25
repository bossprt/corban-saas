-- PREPARED, NOT APPLIED. Forward-only. Finding: the Supabase performance advisor raised `multiple_permissive_policies` (WARN) on
-- public.organization_memberships for role authenticated / action SELECT after 20260925_team_access_lifecycle_v1 added
-- `organization_memberships_select_team` next to the existing `organization_memberships_select_self`.
-- Two permissive policies are OR-ed, so ONE policy with the same two conditions is logically identical and evaluated once.
-- Nothing else changes: same predicates, same roles, no grant change, no function change.
drop policy organization_memberships_select_self on public.organization_memberships;
drop policy organization_memberships_select_team on public.organization_memberships;
create policy organization_memberships_select on public.organization_memberships for select to authenticated
 using (
  (user_id = (select auth.uid()) and status = 'active')
  or private.caller_role_in(organization_id) in ('admin','manager')
 );
