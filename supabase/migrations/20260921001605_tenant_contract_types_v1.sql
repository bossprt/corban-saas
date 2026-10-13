-- CORBAN OS — Tenant contract type management V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Global platform types remain visible; tenants may add their own types and configure visibility/usage without duplicating a type per Product/Table.

alter table public.contract_types
  add column organization_id uuid references public.organizations(id) on delete restrict,
  add column created_by uuid references auth.users(id) on delete set null,
  add column updated_at timestamptz not null default now();

-- Refin/Portabilidade is a distinct operational contract type used for refinancing a portability contract.
insert into public.contract_types(tech_key,name,is_active,sort_order)
values ('refin_portabilidade','Refin/Portabilidade',true,50)
on conflict (tech_key) do update
set name=excluded.name,is_active=true,sort_order=excluded.sort_order;

drop index if exists public.contract_types_name_key;
create unique index contract_types_global_name_key on public.contract_types(lower(btrim(name))) where organization_id is null;
create unique index contract_types_tenant_name_key on public.contract_types(organization_id,lower(btrim(name))) where organization_id is not null;
create index contract_types_organization_idx on public.contract_types(organization_id) where organization_id is not null;

create table public.organization_contract_type_settings(
  organization_id uuid not null references public.organizations(id) on delete restrict,
  contract_type_id uuid not null references public.contract_types(id) on delete restrict,
  is_enabled boolean not null default true,
  use_in_pipeline boolean not null default true,
  use_in_commission boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (organization_id,contract_type_id)
);
create index organization_contract_type_settings_type_idx on public.organization_contract_type_settings(contract_type_id);

create or replace function public.guard_contract_type_catalog()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then
      if new.organization_id is null then raise exception 'global_contract_type_is_platform_managed'; end if;
      if not public.has_active_organization_role(new.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
      new.created_by:=auth.uid();
      if new.tech_key is null or length(btrim(new.tech_key))<8 then new.tech_key:='tenant_'||replace(gen_random_uuid()::text,'-',''); end if;
    end if;
  else
    if old.organization_id is null and current_user in ('authenticated','anon') then raise exception 'global_contract_type_is_platform_managed'; end if;
    if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.tech_key is distinct from old.tech_key or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then raise exception 'contract_type_identity_is_immutable'; end if;
    new.updated_at:=now();
  end if;
  return new;
end $$;
create trigger contract_types_00_guard before insert or update on public.contract_types for each row execute function public.guard_contract_type_catalog();

create or replace function public.guard_contract_type_setting()
returns trigger language plpgsql set search_path='' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.contract_types where id=new.contract_type_id;
  if v_org is not null and v_org is distinct from new.organization_id then raise exception 'cross_tenant_contract_type'; end if;
  if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
  new.updated_at:=now();
  return new;
end $$;
create trigger organization_contract_type_settings_00_guard before insert or update on public.organization_contract_type_settings for each row execute function public.guard_contract_type_setting();

create or replace function public.guard_condition_contract_type_scope()
returns trigger language plpgsql set search_path='' as $$
declare v_type_org uuid; v_active boolean; v_enabled boolean;
begin
  select organization_id,is_active into v_type_org,v_active from public.contract_types where id=new.contract_type_id;
  if not found or not v_active then raise exception 'contract_type_not_found'; end if;
  if v_type_org is not null and v_type_org is distinct from new.organization_id then raise exception 'cross_tenant_contract_type'; end if;
  select s.is_enabled into v_enabled from public.organization_contract_type_settings s where s.organization_id=new.organization_id and s.contract_type_id=new.contract_type_id;
  if v_enabled is false then raise exception 'contract_type_disabled'; end if;
  return new;
end $$;
create trigger commercial_conditions_01_contract_type_scope before insert or update of contract_type_id,organization_id on public.commercial_conditions for each row execute function public.guard_condition_contract_type_scope();

drop policy if exists contract_types_read on public.contract_types;
revoke all on public.contract_types from public,anon,authenticated;
grant select,insert,update on public.contract_types to authenticated;
create policy contract_types_read on public.contract_types for select to authenticated
using (organization_id is null or public.is_active_organization_member(organization_id));
create policy contract_types_insert_manager on public.contract_types for insert to authenticated
with check (organization_id is not null and public.has_active_organization_role(organization_id,array['admin','manager']));
create policy contract_types_update_manager on public.contract_types for update to authenticated
using (organization_id is not null and public.has_active_organization_role(organization_id,array['admin','manager']))
with check (organization_id is not null and public.has_active_organization_role(organization_id,array['admin','manager']));

alter table public.organization_contract_type_settings enable row level security;
revoke all on public.organization_contract_type_settings from public,anon,authenticated;
grant select,insert,update on public.organization_contract_type_settings to authenticated;
create policy organization_contract_type_settings_select on public.organization_contract_type_settings for select to authenticated
using (public.is_active_organization_member(organization_id));
create policy organization_contract_type_settings_insert_manager on public.organization_contract_type_settings for insert to authenticated
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy organization_contract_type_settings_update_manager on public.organization_contract_type_settings for update to authenticated
using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_contract_type_catalog() from public,anon,authenticated;
revoke all on function public.guard_contract_type_setting() from public,anon,authenticated;
revoke all on function public.guard_condition_contract_type_scope() from public,anon,authenticated;
