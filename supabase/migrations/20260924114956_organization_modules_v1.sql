-- F1 step 5c: modules per company (approved by the owner on 2026-09-24, MAPA-OPERACAO §15).
--
-- The platform turns modules on or off for each company, which is how plans limit what a company can use.
-- Every company starts with every module on, so nothing changes for existing companies.
-- A permission counts only while its module is on: public.has_permission now checks both.
-- Only the platform (service role, from the platform admin console) writes; companies read their own modules.

create or replace function private.module_catalog()
returns text[]
language sql
immutable
set search_path to ''
as $$
  select array['clientes','leads','propostas','esteira','comercial','financeiro','repasse','relatorios','equipe','configuracoes','integracoes',
               'portal_corretor','campanhas','ia','api']
$$;

revoke all on function private.module_catalog() from public;
grant execute on function private.module_catalog() to authenticated;

create table public.organization_modules (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  module_key text not null check (module_key = any (private.module_catalog())),
  enabled boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (organization_id, module_key)
);

alter table public.organization_modules enable row level security;
revoke all on table public.organization_modules from anon, authenticated;
grant select on table public.organization_modules to authenticated;

create policy organization_modules_select_member on public.organization_modules
  for select to authenticated
  using (public.is_active_organization_member(organization_id));

create or replace function private.ensure_default_modules(p_org uuid)
returns void
language sql
security definer
set search_path to ''
as $$
  insert into public.organization_modules (organization_id, module_key, enabled)
  select p_org, m, true from unnest(private.module_catalog()) m
  on conflict (organization_id, module_key) do nothing
$$;

revoke all on function private.ensure_default_modules(uuid) from public, anon, authenticated;

create or replace function public.organizations_default_modules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform private.ensure_default_modules(new.id);
  return new;
end
$$;

revoke all on function public.organizations_default_modules() from public, anon, authenticated;

create trigger organizations_20_default_modules
  after insert on public.organizations
  for each row execute function public.organizations_default_modules();

do $$
declare v_org uuid;
begin
  for v_org in select id from public.organizations loop
    perform private.ensure_default_modules(v_org);
  end loop;
end $$;

-- Fail closed: a module without a row is off.
create or replace function public.module_enabled(p_org uuid, p_module text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select m.enabled from public.organization_modules m where m.organization_id = p_org and m.module_key = p_module), false)
$$;

revoke all on function public.module_enabled(uuid, text) from public, anon;
grant execute on function public.module_enabled(uuid, text) to authenticated;

-- Modules on for the caller's company (members only).
create or replace function public.my_modules(p_org uuid)
returns text[]
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(array_agg(m.module_key order by m.module_key), '{}')
  from public.organization_modules m
  where m.organization_id = p_org and m.enabled
    and exists (select 1 from public.organization_memberships x where x.organization_id = p_org and x.user_id = (select auth.uid()) and x.status = 'active')
$$;

revoke all on function public.my_modules(uuid) from public, anon;
grant execute on function public.my_modules(uuid) to authenticated;

-- A permission counts only while its module is on.
create or replace function public.has_permission(p_org uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select public.module_enabled(p_org, split_part(p_permission, '.', 1)) and exists (
    select 1
    from public.organization_memberships m
    join public.organization_roles r on r.organization_id = m.organization_id and r.id = m.role_id
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active' and r.is_active
      and (r.tier = 'admin' or p_permission = any (r.permissions))
  )
$$;
