-- F1 step 5c hardening: module_enabled answers only for companies where the caller is an active member,
-- so no one can read another company's plan. has_permission already requires membership.

create or replace function public.module_enabled(p_org uuid, p_module text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select m.enabled from public.organization_modules m
    where m.organization_id = p_org and m.module_key = p_module
      and exists (select 1 from public.organization_memberships x where x.organization_id = p_org and x.user_id = (select auth.uid()) and x.status = 'active')
  ), false)
$$;