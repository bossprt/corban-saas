-- F1 step 5b: data scope visibility (approved by the owner on 2026-09-24, MAPA-OPERACAO §14).
--
-- Every role has a scope: own, team, branch or all (the administrator tier always sees all). A member may get a
-- per-person exception (scope_override). Visibility is enforced by RESTRICTIVE policies, which are ANDed with the
-- permissive policies already in place: nothing that is visible today becomes more visible, and the existing
-- tenant and role rules stay exactly as they are.
--
-- Owner of a record:
--   clients        owner_user_id (new; set to the creator on insert)
--   leads          owner_user_id, else created_by
--   proposals_v2   the user bound to the attributed seller, else created_by
--   simulations    created_by
-- A client is also visible to whoever can see one of its leads or proposals. Child tables follow their client,
-- proposal or lead.

-- Hierarchy on memberships -----------------------------------------------------------------------------------

alter table public.organization_memberships
  add column branch_id uuid,
  add column team_leader_user_id uuid,
  add column scope_override text check (scope_override in ('own','team','branch','all'));

alter table public.organization_memberships
  add constraint organization_memberships_branch_fk foreign key (organization_id, branch_id)
  references public.organization_branches (organization_id, id) on delete restrict;

create index organization_memberships_branch_idx on public.organization_memberships (organization_id, branch_id);
create index organization_memberships_leader_idx on public.organization_memberships (organization_id, team_leader_user_id);

-- Client owner -------------------------------------------------------------------------------------------------

alter table public.clients add column owner_user_id uuid;
create index clients_owner_idx on public.clients (organization_id, owner_user_id);

create or replace function public.set_client_owner()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.owner_user_id is null then new.owner_user_id := auth.uid(); end if;
  elsif new.owner_user_id is distinct from old.owner_user_id and current_user in ('authenticated','anon')
        and current_setting('corban.hierarchy_rpc', true) is distinct from 'on' then
    raise exception 'client_owner_change_requires_governed_rpc';
  end if;
  return new;
end
$$;

revoke all on function public.set_client_owner() from public, anon, authenticated;

create trigger clients_05_owner
  before insert or update on public.clients
  for each row execute function public.set_client_owner();

-- Visibility functions (security definer: they read memberships and roles for the caller only) ----------------

-- The caller's effective scope and branch in a company; no row when the caller is not an active member.
create or replace function private.caller_visibility(p_org uuid)
returns table (user_id uuid, scope text, branch_id uuid)
language sql
stable
security definer
set search_path to ''
as $$
  select m.user_id,
         case when m.role = 'admin' then 'all' else coalesce(m.scope_override, r.scope, 'own') end,
         m.branch_id
  from public.organization_memberships m
  left join public.organization_roles r on r.organization_id = m.organization_id and r.id = m.role_id
  where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active'
$$;

create or replace function private.can_see_owner(p_org uuid, p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((
    select case v.scope
      when 'all' then true
      when 'branch' then p_owner is null or p_owner = v.user_id or exists (
        select 1 from public.organization_memberships o
        where o.organization_id = p_org and o.user_id = p_owner and o.branch_id is not distinct from v.branch_id)
      when 'team' then p_owner = v.user_id or exists (
        select 1 from public.organization_memberships o
        where o.organization_id = p_org and o.user_id = p_owner and o.team_leader_user_id = v.user_id)
      else p_owner = v.user_id
    end
    from private.caller_visibility(p_org) v
  ), false)
$$;

create or replace function private.proposal_owner(p_org uuid, p_seller_id uuid, p_created_by uuid)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select s.user_id from public.commercial_sellers s where s.organization_id = p_org and s.id = p_seller_id), p_created_by)
$$;

create or replace function private.can_see_proposal_row(p_org uuid, p_seller_id uuid, p_created_by uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select private.can_see_owner(p_org, private.proposal_owner(p_org, p_seller_id, p_created_by))
      or (p_created_by is not null and private.can_see_owner(p_org, p_created_by))
$$;

create or replace function private.can_see_client_row(p_org uuid, p_client_id uuid, p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select private.can_see_owner(p_org, p_owner)
      or exists (select 1 from public.leads l
                 where l.organization_id = p_org and l.customer_id = p_client_id
                   and private.can_see_owner(p_org, coalesce(l.owner_user_id, l.created_by)))
      or exists (select 1 from public.proposals_v2 p
                 where p.organization_id = p_org and p.customer_id = p_client_id
                   and private.can_see_proposal_row(p_org, p.seller_id, p.created_by))
$$;

revoke all on function private.caller_visibility(uuid) from public, anon;
revoke all on function private.can_see_owner(uuid, uuid) from public, anon;
revoke all on function private.proposal_owner(uuid, uuid, uuid) from public, anon;
revoke all on function private.can_see_proposal_row(uuid, uuid, uuid) from public, anon;
revoke all on function private.can_see_client_row(uuid, uuid, uuid) from public, anon;
grant execute on function private.caller_visibility(uuid) to authenticated;
grant execute on function private.can_see_owner(uuid, uuid) to authenticated;
grant execute on function private.proposal_owner(uuid, uuid, uuid) to authenticated;
grant execute on function private.can_see_proposal_row(uuid, uuid, uuid) to authenticated;
grant execute on function private.can_see_client_row(uuid, uuid, uuid) to authenticated;

-- Restrictive policies on the owning tables ---------------------------------------------------------------------

create policy clients_scope on public.clients as restrictive for all to authenticated
  using (private.can_see_client_row(organization_id, id, owner_user_id))
  with check (private.can_see_client_row(organization_id, id, owner_user_id));

create policy leads_scope on public.leads as restrictive for all to authenticated
  using (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by)))
  with check (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by)));

create policy proposals_v2_scope on public.proposals_v2 as restrictive for all to authenticated
  using (private.can_see_proposal_row(organization_id, seller_id, created_by))
  with check (private.can_see_proposal_row(organization_id, seller_id, created_by));

create policy simulations_scope on public.simulations as restrictive for all to authenticated
  using (private.can_see_owner(organization_id, created_by)
         or (customer_id is not null and exists (select 1 from public.clients c where c.id = customer_id)))
  with check (private.can_see_owner(organization_id, created_by)
         or (customer_id is not null and exists (select 1 from public.clients c where c.id = customer_id)));

-- Child tables follow their parent (the subquery runs under the parent's RLS) --------------------------------------

do $$
declare t text;
begin
  foreach t in array array['customer_addresses','customer_bank_accounts','customer_documents','customer_pix_keys','customer_timeline_events'] loop
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (exists (select 1 from public.clients c where c.id = customer_id)) with check (exists (select 1 from public.clients c where c.id = customer_id))', t || '_scope', t);
  end loop;
  foreach t in array array['digitization_jobs','operational_cases','proposal_commercial_component_snapshots','proposal_commercial_snapshots','proposal_document_requirements','proposal_external_identities','proposal_seller_commission_snapshots','proposal_status_evidence','financial_events','financial_reconciliation_cases','import_match_candidates'] loop
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (proposal_id is null or exists (select 1 from public.proposals_v2 p where p.id = proposal_id)) with check (proposal_id is null or exists (select 1 from public.proposals_v2 p where p.id = proposal_id))', t || '_scope', t);
  end loop;
end $$;

create policy lead_events_scope on public.lead_events as restrictive for all to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id))
  with check (exists (select 1 from public.leads l where l.id = lead_id));

-- Governed hierarchy changes ------------------------------------------------------------------------------------

alter table public.organization_admin_events drop constraint if exists organization_admin_events_event_type_check;
alter table public.organization_admin_events add constraint organization_admin_events_event_type_check check (event_type = any (array[
  'invite_created','invite_revoked','invite_accepted','member_role_changed','member_deactivated','member_reactivated',
  'seller_created','seller_user_binding_updated','seller_supervision_updated','role_created','role_updated','member_access_role_changed',
  'member_hierarchy_changed'
]));

-- Branch, team leader and scope exception of a member. Administrators and managers, same authority as role changes.
create or replace function public.set_member_hierarchy(p_membership_id uuid, p_branch_id uuid, p_team_leader_user_id uuid, p_scope_override text)
returns void
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v public.organization_memberships%rowtype;
  v_actor text;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into v from public.organization_memberships m where m.id = p_membership_id for update;
  if not found then raise exception 'membership_not_found'; end if;
  v_actor := private.caller_role_in(v.organization_id);
  if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if not public.can_manage_member_role(v_actor, v.role, v.role) then raise exception 'role_change_not_permitted'; end if;
  if p_scope_override is not null and p_scope_override not in ('own','team','branch','all') then raise exception 'invalid_role_scope'; end if;
  if p_scope_override = 'all' and v_actor <> 'admin' then raise exception 'role_change_not_permitted'; end if;
  if p_branch_id is not null and not exists (
    select 1 from public.organization_branches b where b.organization_id = v.organization_id and b.id = p_branch_id and b.is_active
  ) then raise exception 'branch_not_found'; end if;
  if p_team_leader_user_id is not null and (p_team_leader_user_id = v.user_id or not exists (
    select 1 from public.organization_memberships l where l.organization_id = v.organization_id and l.user_id = p_team_leader_user_id and l.status = 'active'
  )) then raise exception 'team_leader_not_found'; end if;
  if v.branch_id is not distinct from p_branch_id and v.team_leader_user_id is not distinct from p_team_leader_user_id
     and v.scope_override is not distinct from p_scope_override then raise exception 'no_change'; end if;

  perform set_config('corban.membership_rpc', 'on', true);
  update public.organization_memberships
  set branch_id = p_branch_id, team_leader_user_id = p_team_leader_user_id, scope_override = p_scope_override, updated_at = now()
  where id = p_membership_id;
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, target_user_id, details)
  values (v.organization_id, auth.uid(), 'member_hierarchy_changed', v.user_id, jsonb_build_object(
    'from', jsonb_build_object('branch_id', v.branch_id, 'team_leader_user_id', v.team_leader_user_id, 'scope_override', v.scope_override),
    'to', jsonb_build_object('branch_id', p_branch_id, 'team_leader_user_id', p_team_leader_user_id, 'scope_override', p_scope_override)));
  perform set_config('corban.membership_rpc', 'off', true);
end
$$;

revoke all on function public.set_member_hierarchy(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.set_member_hierarchy(uuid, uuid, uuid, text) to authenticated;
