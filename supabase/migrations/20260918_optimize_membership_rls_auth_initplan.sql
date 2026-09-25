drop policy if exists organization_memberships_select_self on public.organization_memberships;
create policy organization_memberships_select_self
on public.organization_memberships
for select
to authenticated
using (
  user_id = (select auth.uid())
  and status = 'active'
);