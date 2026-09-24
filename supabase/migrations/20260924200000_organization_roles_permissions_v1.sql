-- F1 step 5a: organization roles and permissions (approved by the owner on 2026-09-24, MAPA-OPERACAO §14).
--
-- Each company has roles: seven system roles created automatically plus custom roles the owner creates.
-- A role carries:
--   tier        the access level the existing RLS policies already check (admin, manager, supervisor, agent).
--               organization_memberships.role is kept equal to the assigned role's tier by a trigger, so the
--               131 role-based policies in place keep their exact behavior.
--   permissions fine-grained module.action grants, checked by public.has_permission(). New policies and RPCs
--               (F2 onward) check permissions; old ones migrate module by module.
--   scope       data visibility (own, team, branch, all). Stored now, enforced in step 5b.
-- Writes go only through governed RPCs; there is no direct table write for authenticated users.

-- Permission catalog -----------------------------------------------------------------------------------------

create or replace function private.permission_catalog()
returns text[]
language sql
immutable
set search_path to ''
as $$
  select array_agg(m || '.' || a order by m, a)
  from unnest(array['clientes','leads','propostas','esteira','comercial','financeiro','repasse','relatorios','equipe','configuracoes','integracoes']) m
  cross join unnest(array['view','create','edit','approve']) a
$$;

revoke all on function private.permission_catalog() from public;
grant execute on function private.permission_catalog() to authenticated;

-- Roles --------------------------------------------------------------------------------------------------------

create table public.organization_roles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  key text not null check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null check (length(btrim(name)) between 2 and 60),
  tier text not null check (tier in ('admin','manager','supervisor','agent')),
  scope text not null check (scope in ('own','team','branch','all')),
  permissions text[] not null default '{}',
  is_system boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  unique (organization_id, key),
  unique (organization_id, id),
  constraint organization_roles_permissions_known check (permissions <@ private.permission_catalog()),
  constraint organization_roles_admin_is_system check (tier <> 'admin' or is_system)
);

alter table public.organization_roles enable row level security;
revoke all on table public.organization_roles from anon, authenticated;
grant select, insert, update on table public.organization_roles to authenticated;

create policy organization_roles_select_member on public.organization_roles
  for select to authenticated
  using (public.is_active_organization_member(organization_id));

-- Writes are additionally gated by the guard trigger (only inside save_organization_role).
create policy organization_roles_insert_admin on public.organization_roles
  for insert to authenticated
  with check (private.caller_role_in(organization_id) = 'admin');

create policy organization_roles_update_admin on public.organization_roles
  for update to authenticated
  using (private.caller_role_in(organization_id) = 'admin')
  with check (private.caller_role_in(organization_id) = 'admin');

create or replace function public.guard_organization_role_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_user in ('authenticated','anon') and current_setting('corban.role_rpc', true) is distinct from 'on' then
    raise exception 'organization_role_write_requires_governed_rpc';
  end if;
  if tg_op = 'DELETE' then raise exception 'organization_role_delete_forbidden'; end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
       or new.key is distinct from old.key or new.is_system is distinct from old.is_system
       or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then
      raise exception 'organization_role_identity_immutable';
    end if;
    if old.is_system and new.tier is distinct from old.tier then raise exception 'system_role_tier_immutable'; end if;
    new.updated_at := now();
  end if;
  return new;
end
$$;

revoke all on function public.guard_organization_role_write() from public, anon, authenticated;

create trigger organization_roles_00_guard
  before insert or update or delete on public.organization_roles
  for each row execute function public.guard_organization_role_write();

create index organization_roles_org_idx on public.organization_roles (organization_id);

-- System roles for one company. Idempotent: existing roles are left as they are.
create or replace function private.ensure_default_roles(p_org uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_all text[] := private.permission_catalog();
  v_ops text[] := array['clientes.view','clientes.create','clientes.edit','leads.view','leads.create','leads.edit','propostas.view','propostas.create','propostas.edit','esteira.view','esteira.create','esteira.edit'];
begin
  perform set_config('corban.role_rpc', 'on', true);
  insert into public.organization_roles (organization_id, key, name, tier, scope, permissions, is_system)
  values
    (p_org, 'admin',      'Administrador',   'admin',      'all',    v_all, true),
    (p_org, 'gerente',    'Gerente',         'manager',    'branch', array(select p from unnest(v_all) p where p not like 'configuracoes.%' or p = 'configuracoes.view'), true),
    (p_org, 'supervisor', 'Supervisor',      'supervisor', 'team',   v_ops || array['leads.approve','propostas.approve','esteira.approve','comercial.view','financeiro.view','relatorios.view'], true),
    (p_org, 'financeiro', 'Financeiro',      'supervisor', 'all',    array['clientes.view','propostas.view','esteira.view','comercial.view','relatorios.view','financeiro.view','financeiro.create','financeiro.edit','financeiro.approve','repasse.view','repasse.create','repasse.edit','repasse.approve'], true),
    (p_org, 'operador',   'Operador',        'agent',      'all',    v_ops, true),
    (p_org, 'vendedor',   'Vendedor',        'agent',      'own',    array['clientes.view','clientes.create','clientes.edit','leads.view','leads.create','leads.edit','propostas.view','propostas.create','esteira.view'], true),
    (p_org, 'corretor',   'Corretor externo','agent',      'own',    array['clientes.view','clientes.create','propostas.view','propostas.create','esteira.view'], true)
  on conflict (organization_id, key) do nothing;
  perform set_config('corban.role_rpc', 'off', true);
end
$$;

revoke all on function private.ensure_default_roles(uuid) from public, anon, authenticated;

create or replace function public.organizations_default_roles()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform private.ensure_default_roles(new.id);
  return new;
end
$$;

revoke all on function public.organizations_default_roles() from public, anon, authenticated;

create trigger organizations_10_default_roles
  after insert on public.organizations
  for each row execute function public.organizations_default_roles();

do $$
declare v_org uuid;
begin
  for v_org in select id from public.organizations loop
    perform private.ensure_default_roles(v_org);
  end loop;
end $$;

-- Memberships point to a role; the tier column follows it ----------------------------------------------------

alter table public.organization_memberships add column role_id uuid;
alter table public.organization_memberships
  add constraint organization_memberships_role_fk foreign key (organization_id, role_id)
  references public.organization_roles (organization_id, id) on delete restrict;
create index organization_memberships_role_idx on public.organization_memberships (organization_id, role_id);

-- Default system role for a tier, used when only the tier is given (invitations, the legacy set_member_role).
create or replace function private.default_role_for_tier(p_org uuid, p_tier text)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select r.id from public.organization_roles r
  where r.organization_id = p_org and r.is_system
    and r.key = case p_tier when 'admin' then 'admin' when 'manager' then 'gerente' when 'supervisor' then 'supervisor' when 'agent' then 'vendedor' end
$$;

revoke all on function private.default_role_for_tier(uuid, text) from public, anon, authenticated;

create or replace function public.sync_membership_role_tier()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_tier text;
begin
  if new.role_id is not null and (tg_op = 'INSERT' or new.role_id is distinct from old.role_id) then
    select r.tier into v_tier from public.organization_roles r
    where r.organization_id = new.organization_id and r.id = new.role_id and r.is_active;
    if v_tier is null then raise exception 'organization_role_not_found'; end if;
    new.role := v_tier;
  elsif tg_op = 'INSERT' or new.role is distinct from old.role then
    -- Only the tier was given (invitation, legacy set_member_role) or the role's own tier changed (save_organization_role).
    -- Keep the current role while its tier matches; otherwise fall back to the system role of that tier.
    select r.tier into v_tier from public.organization_roles r
    where r.organization_id = new.organization_id and r.id = new.role_id;
    if new.role_id is null or v_tier is distinct from new.role then
      new.role_id := private.default_role_for_tier(new.organization_id, new.role);
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.sync_membership_role_tier() from public, anon, authenticated;

create trigger organization_memberships_10_role_tier
  before insert or update on public.organization_memberships
  for each row execute function public.sync_membership_role_tier();

update public.organization_memberships m
set role_id = private.default_role_for_tier(m.organization_id, m.role)
where m.role_id is null;

-- Permission checks ------------------------------------------------------------------------------------------

create or replace function public.has_permission(p_org uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1
    from public.organization_memberships m
    join public.organization_roles r on r.organization_id = m.organization_id and r.id = m.role_id
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active' and r.is_active
      and (r.tier = 'admin' or p_permission = any (r.permissions))
  )
$$;

revoke all on function public.has_permission(uuid, text) from public, anon;
grant execute on function public.has_permission(uuid, text) to authenticated;

-- The caller's own access in one company, for the application to mirror (the database stays the authority).
create or replace function public.my_access(p_org uuid)
returns table (role_id uuid, role_key text, role_name text, tier text, scope text, permissions text[])
language sql
stable
security definer
set search_path to ''
as $$
  select r.id, r.key, r.name, r.tier, r.scope,
         case when r.tier = 'admin' then private.permission_catalog() else r.permissions end
  from public.organization_memberships m
  join public.organization_roles r on r.organization_id = m.organization_id and r.id = m.role_id
  where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active'
$$;

revoke all on function public.my_access(uuid) from public, anon;
grant execute on function public.my_access(uuid) to authenticated;

-- Governed writes ----------------------------------------------------------------------------------------------

alter table public.organization_admin_events drop constraint if exists organization_admin_events_event_type_check;
alter table public.organization_admin_events add constraint organization_admin_events_event_type_check check (event_type = any (array[
  'invite_created','invite_revoked','invite_accepted','member_role_changed','member_deactivated','member_reactivated',
  'seller_created','seller_user_binding_updated','seller_supervision_updated','role_created','role_updated','member_access_role_changed'
]));

-- Create or update a role. Administrators only. The system administrator role cannot change; system roles keep key and tier.
create or replace function public.save_organization_role(
  p_org uuid, p_role_id uuid, p_key text, p_name text, p_tier text, p_scope text, p_permissions text[], p_is_active boolean default true
)
returns uuid
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_old public.organization_roles%rowtype;
  v_id uuid;
  v_perms text[];
begin
  if auth.uid() is null or private.caller_role_in(p_org) is distinct from 'admin' then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 60 then raise exception 'invalid_role_name'; end if;
  if p_scope not in ('own','team','branch','all') then raise exception 'invalid_role_scope'; end if;
  select coalesce(array_agg(distinct p order by p), '{}') into v_perms from unnest(coalesce(p_permissions, '{}')) p;
  if not v_perms <@ private.permission_catalog() then raise exception 'unknown_permission'; end if;

  -- corban.membership_rpc also admits the audit event and the member tier update.
  perform set_config('corban.role_rpc', 'on', true);
  perform set_config('corban.membership_rpc', 'on', true);
  if p_role_id is null then
    if p_tier not in ('manager','supervisor','agent') then raise exception 'invalid_role_tier'; end if;
    if p_key is null or p_key !~ '^[a-z][a-z0-9_]{1,39}$' then raise exception 'invalid_role_key'; end if;
    insert into public.organization_roles (organization_id, key, name, tier, scope, permissions, is_system, is_active, created_by, updated_by)
    values (p_org, p_key, btrim(p_name), p_tier, p_scope, v_perms, false, coalesce(p_is_active, true), auth.uid(), auth.uid())
    returning id into v_id;
    insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
    values (p_org, auth.uid(), 'role_created', jsonb_build_object('role_id', v_id, 'key', p_key, 'tier', p_tier, 'scope', p_scope, 'permissions', v_perms));
  else
    select * into v_old from public.organization_roles where organization_id = p_org and id = p_role_id for update;
    if not found then raise exception 'organization_role_not_found'; end if;
    if v_old.tier = 'admin' then raise exception 'admin_role_is_fixed'; end if;
    if v_old.is_system and p_tier is distinct from v_old.tier then raise exception 'system_role_tier_immutable'; end if;
    if not v_old.is_system and p_tier not in ('manager','supervisor','agent') then raise exception 'invalid_role_tier'; end if;
    if coalesce(p_is_active, true) = false and exists (
      select 1 from public.organization_memberships m where m.organization_id = p_org and m.role_id = p_role_id and m.status = 'active'
    ) then raise exception 'role_in_use'; end if;
    update public.organization_roles
    set name = btrim(p_name), tier = p_tier, scope = p_scope, permissions = v_perms, is_active = coalesce(p_is_active, true), updated_by = auth.uid()
    where organization_id = p_org and id = p_role_id;
    -- Members follow a changed tier (custom roles only).
    if p_tier is distinct from v_old.tier then
      update public.organization_memberships set role = p_tier, updated_at = now() where organization_id = p_org and role_id = p_role_id;
    end if;
    v_id := p_role_id;
    insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
    values (p_org, auth.uid(), 'role_updated', jsonb_build_object('role_id', v_id, 'from', jsonb_build_object('name', v_old.name, 'tier', v_old.tier, 'scope', v_old.scope, 'permissions', v_old.permissions, 'is_active', v_old.is_active), 'to', jsonb_build_object('name', btrim(p_name), 'tier', p_tier, 'scope', p_scope, 'permissions', v_perms, 'is_active', coalesce(p_is_active, true))));
  end if;
  perform set_config('corban.membership_rpc', 'off', true);
  perform set_config('corban.role_rpc', 'off', true);
  return v_id;
end
$$;

revoke all on function public.save_organization_role(uuid, uuid, text, text, text, text, text[], boolean) from public, anon;
grant execute on function public.save_organization_role(uuid, uuid, text, text, text, text, text[], boolean) to authenticated;

-- Give a member one of the company's roles. Same authority matrix as set_member_role, applied to the role's tier.
create or replace function public.assign_member_access_role(p_membership_id uuid, p_role_id uuid)
returns void
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v public.organization_memberships%rowtype;
  v_actor text;
  v_tier text;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into v from public.organization_memberships m where m.id = p_membership_id for update;
  if not found then raise exception 'membership_not_found'; end if;
  v_actor := private.caller_role_in(v.organization_id);
  if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if v.user_id = auth.uid() then raise exception 'cannot_change_own_membership'; end if;
  select r.tier into v_tier from public.organization_roles r where r.organization_id = v.organization_id and r.id = p_role_id and r.is_active;
  if v_tier is null then raise exception 'organization_role_not_found'; end if;
  if not public.can_manage_member_role(v_actor, v.role, v_tier) then raise exception 'role_change_not_permitted'; end if;
  if v.role_id = p_role_id then raise exception 'no_change'; end if;
  perform set_config('corban.membership_rpc', 'on', true);
  update public.organization_memberships set role_id = p_role_id, updated_at = now() where id = p_membership_id;
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, target_user_id, details)
  values (v.organization_id, auth.uid(), 'member_access_role_changed', v.user_id, jsonb_build_object('from_role_id', v.role_id, 'to_role_id', p_role_id, 'from_tier', v.role, 'to_tier', v_tier));
  perform set_config('corban.membership_rpc', 'off', true);
end
$$;

revoke all on function public.assign_member_access_role(uuid, uuid) from public, anon;
grant execute on function public.assign_member_access_role(uuid, uuid) to authenticated;
