-- CORBAN OS V2 — Tenant/Auth/Membership foundation
-- Additive migration draft. Designed to preserve legacy profiles.organization_id.
-- IMPORTANT: this file is versioned before application. Do not edit after application.

create table if not exists public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_memberships_role_check
    check (role in ('admin','manager','supervisor','agent')),
  constraint organization_memberships_status_check
    check (status in ('active','inactive','revoked')),
  constraint organization_memberships_org_user_key
    unique (organization_id, user_id)
);

create index if not exists organization_memberships_user_status_idx
  on public.organization_memberships (user_id, status);

create index if not exists organization_memberships_org_status_idx
  on public.organization_memberships (organization_id, status);

alter table public.organization_memberships enable row level security;

-- Transitional backfill. Currently expected to affect zero rows, but kept idempotent
-- so environments with legacy profiles can migrate safely.
insert into public.organization_memberships (organization_id, user_id, role, status)
select p.organization_id, p.id, coalesce(p.role, 'agent'), 'active'
from public.profiles p
where p.organization_id is not null
on conflict (organization_id, user_id) do nothing;

create or replace function public.is_active_organization_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships m
    where m.organization_id = target_organization_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
$$;

revoke all on function public.is_active_organization_member(uuid) from public;
revoke all on function public.is_active_organization_member(uuid) from anon;
grant execute on function public.is_active_organization_member(uuid) to authenticated;
grant execute on function public.is_active_organization_member(uuid) to service_role;

revoke all on table public.organization_memberships from anon;
grant select on table public.organization_memberships to authenticated;
grant select, insert, update, delete on table public.organization_memberships to service_role;

drop policy if exists organization_memberships_select_self on public.organization_memberships;
create policy organization_memberships_select_self
on public.organization_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  and status = 'active'
);

comment on table public.organization_memberships is
  'Explicit tenant memberships for Corban OS V2. Mutations are backend/service controlled; authenticated users only read their active memberships.';
