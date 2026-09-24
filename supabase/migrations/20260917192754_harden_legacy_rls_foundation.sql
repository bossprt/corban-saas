create or replace function public.get_user_organization_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.organization_id
  from public.profiles p
  where p.id = auth.uid()
  limit 1
$$;

revoke all on function public.get_user_organization_id() from public;
revoke all on function public.get_user_organization_id() from anon;
grant execute on function public.get_user_organization_id() to authenticated;
grant execute on function public.get_user_organization_id() to service_role;

revoke all on table public.organizations, public.profiles, public.clients, public.contracts, public.import_jobs from anon;
revoke truncate, trigger, references on table public.organizations, public.profiles, public.clients, public.contracts, public.import_jobs from authenticated;

grant select, insert, update, delete on table public.organizations, public.profiles, public.clients, public.contracts, public.import_jobs to authenticated;