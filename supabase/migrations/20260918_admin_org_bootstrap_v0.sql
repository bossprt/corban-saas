-- Platform administrators are distinct from tenant organization admins.
create table if not exists public.platform_administrators (
  user_id uuid primary key references auth.users(id) on delete cascade,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  constraint platform_administrators_status_check check (status in ('active','inactive','revoked'))
);

alter table public.platform_administrators enable row level security;
revoke all on table public.platform_administrators from public, anon, authenticated;
grant select, insert, update, delete on table public.platform_administrators to service_role;

create table if not exists public.platform_admin_audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  action text not null,
  target_user_id uuid references auth.users(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete restrict,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
alter table public.platform_admin_audit_events enable row level security;
revoke all on table public.platform_admin_audit_events from public, anon, authenticated;
grant select, insert on table public.platform_admin_audit_events to service_role;
create index if not exists platform_admin_audit_actor_time_idx
  on public.platform_admin_audit_events (actor_user_id, occurred_at desc);
create index if not exists platform_admin_audit_target_user_idx
  on public.platform_admin_audit_events (target_user_id);
create index if not exists platform_admin_audit_org_idx
  on public.platform_admin_audit_events (organization_id);

-- Atomic bootstrap primitive for first tenant membership.
-- SECURITY DEFINER is intentionally NOT executable by authenticated/anon.
create or replace function public.bootstrap_organization_admin(
  p_platform_actor_user_id uuid,
  p_user_id uuid,
  p_organization_name text,
  p_organization_document text,
  p_plan_type text default 'founder'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
begin
  if not exists (
    select 1 from public.platform_administrators pa
    where pa.user_id = p_platform_actor_user_id and pa.status = 'active'
  ) then raise exception 'active_platform_admin_required'; end if;
  if p_user_id is null then raise exception 'user_id_required'; end if;
  if nullif(btrim(p_organization_name), '') is null then raise exception 'organization_name_required'; end if;
  if nullif(btrim(p_organization_document), '') is null then raise exception 'organization_document_required'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then raise exception 'auth_user_not_found'; end if;
  if exists (select 1 from public.organization_memberships m where m.user_id=p_user_id and m.status='active') then
    raise exception 'user_already_has_active_membership';
  end if;

  insert into public.organizations (name, document, plan_type, is_active)
  values (btrim(p_organization_name), btrim(p_organization_document), p_plan_type, true)
  returning id into v_org_id;

  insert into public.organization_memberships (organization_id,user_id,role,status)
  values (v_org_id,p_user_id,'admin','active');

  -- Transitional compatibility while legacy profiles.organization_id remains.
  insert into public.profiles (id,organization_id,full_name,role)
  select p_user_id,v_org_id,coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),u.email,'Admin'),'admin'
  from auth.users u where u.id=p_user_id
  on conflict (id) do update
    set organization_id=excluded.organization_id, role='admin';

  insert into public.platform_admin_audit_events
    (actor_user_id, action, target_user_id, organization_id, metadata)
  values
    (p_platform_actor_user_id, 'organization.bootstrap_admin', p_user_id, v_org_id,
     jsonb_build_object('plan_type', p_plan_type));

  return v_org_id;
end;
$$;

revoke all on function public.bootstrap_organization_admin(uuid,uuid,text,text,text) from public;
revoke all on function public.bootstrap_organization_admin(uuid,uuid,text,text,text) from anon;
revoke all on function public.bootstrap_organization_admin(uuid,uuid,text,text,text) from authenticated;
grant execute on function public.bootstrap_organization_admin(uuid,uuid,text,text,text) to service_role;
