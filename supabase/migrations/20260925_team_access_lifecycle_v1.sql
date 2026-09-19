-- PREPARED, NOT APPLIED. Team access lifecycle: invitations, governed role/status changes, admin audit trail.
-- No SECURITY DEFINER function is added. Every RPC is SECURITY INVOKER: the caller's RLS and column grants stay in force,
-- and a guard trigger (GUC corban.membership_rpc) refuses any direct write that did not come through these RPCs.
--
-- Policy (mirrored by src/lib/rbac.ts canManageMemberRole):
--   admin   : may invite / change role / deactivate / reactivate anyone in the organization (never themselves).
--   manager : only supervisor and agent, both as the target's current role and as the new role.
--   others  : nothing.
--   nobody changes their own role or status (no self-elevation, no self-lockout). Only admins can touch an admin and nobody can touch themselves,
--   so an organization can never lose its last active admin through these RPCs (proved by the harness); no separate counter is needed.
-- No invitation token exists in this schema: the email link is issued and verified by Supabase Auth.

-- ---------------------------------------------------------------- policy predicate (pure)
create or replace function public.can_manage_member_role(p_actor text, p_target_current text, p_target_new text)
 returns boolean language sql immutable set search_path='' as $$
 select case
  when p_actor='admin' then p_target_new in ('admin','manager','supervisor','agent') and (p_target_current is null or p_target_current in ('admin','manager','supervisor','agent'))
  when p_actor='manager' then p_target_new in ('supervisor','agent') and (p_target_current is null or p_target_current in ('supervisor','agent'))
  else false end
$$;

-- ---------------------------------------------------------------- invitations
create table public.organization_invitations(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 email text not null check (email=lower(btrim(email)) and length(email) between 3 and 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
 role text not null check (role in ('admin','manager','supervisor','agent')),
 status text not null default 'pending' check (status in ('pending','accepted','revoked','expired')),
 invited_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '7 days',
 resolved_at timestamptz,
 accepted_user_id uuid references auth.users(id) on delete set null
);
create unique index organization_invitations_one_pending on public.organization_invitations(organization_id,email) where status='pending';
create index organization_invitations_org_status on public.organization_invitations(organization_id,status,created_at desc);
create index organization_invitations_invited_by on public.organization_invitations(invited_by);
create index organization_invitations_accepted_user on public.organization_invitations(accepted_user_id);
alter table public.organization_invitations enable row level security;
revoke all on public.organization_invitations from public,anon,authenticated;
grant select,insert,update on public.organization_invitations to authenticated;
create policy organization_invitations_select on public.organization_invitations for select to authenticated
 using (private.caller_role_in(organization_id) in ('admin','manager'));
create policy organization_invitations_insert on public.organization_invitations for insert to authenticated
 with check (private.caller_role_in(organization_id) in ('admin','manager'));
create policy organization_invitations_update on public.organization_invitations for update to authenticated
 using (private.caller_role_in(organization_id) in ('admin','manager')) with check (private.caller_role_in(organization_id) in ('admin','manager'));

-- ---------------------------------------------------------------- admin audit trail (append-only)
create table public.organization_admin_events(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 actor_user_id uuid references auth.users(id) on delete set null,
 event_type text not null check (event_type in ('invite_created','invite_revoked','invite_accepted','member_role_changed','member_deactivated','member_reactivated')),
 target_user_id uuid references auth.users(id) on delete set null,
 target_email text,
 details jsonb not null default '{}'::jsonb,
 occurred_at timestamptz not null default now()
);
create index organization_admin_events_org_time on public.organization_admin_events(organization_id,occurred_at desc);
create index organization_admin_events_actor on public.organization_admin_events(actor_user_id);
create index organization_admin_events_target on public.organization_admin_events(target_user_id);
alter table public.organization_admin_events enable row level security;
revoke all on public.organization_admin_events from public,anon,authenticated;
grant select,insert on public.organization_admin_events to authenticated;
create policy organization_admin_events_select on public.organization_admin_events for select to authenticated
 using (private.caller_role_in(organization_id) in ('admin','manager'));
create policy organization_admin_events_insert on public.organization_admin_events for insert to authenticated
 with check (private.caller_role_in(organization_id) in ('admin','manager') and actor_user_id=(select auth.uid()));

-- ---------------------------------------------------------------- memberships: team visibility + governed writes
create policy organization_memberships_select_team on public.organization_memberships for select to authenticated
 using (private.caller_role_in(organization_id) in ('admin','manager'));
create policy organization_memberships_update_team on public.organization_memberships for update to authenticated
 using (private.caller_role_in(organization_id) in ('admin','manager')) with check (private.caller_role_in(organization_id) in ('admin','manager'));
revoke insert,delete,update on public.organization_memberships from authenticated;
grant update(role,status,updated_at) on public.organization_memberships to authenticated;

create or replace function public.guard_membership_write() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='DELETE' then raise exception 'membership_delete_forbidden'; end if;
  if current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'membership_write_requires_governed_rpc'; end if;
 end if;
 if tg_op='UPDATE' and (new.organization_id is distinct from old.organization_id or new.user_id is distinct from old.user_id) then raise exception 'membership_identity_immutable'; end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger organization_memberships_00_governed_write before insert or update or delete on public.organization_memberships for each row execute function public.guard_membership_write();

create or replace function public.guard_invitation_write() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'invitation_delete_forbidden'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'invitation_write_requires_governed_rpc'; end if;
 if tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id or new.email is distinct from old.email or new.role is distinct from old.role
     or new.invited_by is distinct from old.invited_by or new.created_at is distinct from old.created_at or new.expires_at is distinct from old.expires_at then
   raise exception 'invitation_identity_immutable'; end if;
  if old.status<>'pending' then raise exception 'invitation_already_resolved'; end if;
 end if;
 return new;
end $$;
create trigger organization_invitations_00_governed_write before insert or update or delete on public.organization_invitations for each row execute function public.guard_invitation_write();

create or replace function public.guard_admin_event_write() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op<>'INSERT' then raise exception 'admin_events_append_only'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'admin_event_requires_governed_rpc'; end if;
 return new;
end $$;
create trigger organization_admin_events_00_append_only before insert or update or delete on public.organization_admin_events for each row execute function public.guard_admin_event_write();

-- ---------------------------------------------------------------- RPCs (all SECURITY INVOKER)
create or replace function public.create_organization_invitation(p_org uuid, p_email text, p_role text)
 returns uuid language plpgsql set search_path='' as $$
declare v_actor text; v_email text:=lower(btrim(coalesce(p_email,''))); v_id uuid;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 v_actor:=private.caller_role_in(p_org);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if p_role is null or p_role not in ('admin','manager','supervisor','agent') then raise exception 'invalid_role'; end if;
 if not public.can_manage_member_role(v_actor,null,p_role) then raise exception 'role_change_not_permitted'; end if;
 if length(v_email) not between 3 and 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then raise exception 'invalid_email'; end if;
 if (select count(*) from public.organization_invitations i where i.organization_id=p_org and i.invited_by=auth.uid() and i.created_at>now()-interval '1 hour')>=20 then raise exception 'invitation_rate_limited'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_invitations i set status='expired',resolved_at=now() where i.organization_id=p_org and i.email=v_email and i.status='pending' and i.expires_at<=now();
 begin
  insert into public.organization_invitations(organization_id,email,role,invited_by) values(p_org,v_email,p_role,auth.uid()) returning id into v_id;
 exception when unique_violation then
  perform set_config('corban.membership_rpc','off',true);
  raise exception 'invitation_already_pending';
 end;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_email,details) values(p_org,auth.uid(),'invite_created',v_email,jsonb_build_object('role',p_role,'invitation_id',v_id));
 perform set_config('corban.membership_rpc','off',true);
 return v_id;
end $$;

create or replace function public.revoke_organization_invitation(p_invitation_id uuid)
 returns void language plpgsql set search_path='' as $$
declare v public.organization_invitations%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_invitations i where i.id=p_invitation_id for update;
 if not found then raise exception 'invitation_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or not public.can_manage_member_role(v_actor,null,v.role) then raise exception 'not_authorized'; end if;
 if v.status<>'pending' then raise exception 'invitation_already_resolved'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_invitations set status='revoked',resolved_at=now() where id=p_invitation_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_email,details) values(v.organization_id,auth.uid(),'invite_revoked',v.email,jsonb_build_object('role',v.role,'invitation_id',v.id));
 perform set_config('corban.membership_rpc','off',true);
end $$;

create or replace function public.set_member_role(p_membership_id uuid, p_role text)
 returns void language plpgsql set search_path='' as $$
declare v public.organization_memberships%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_memberships m where m.id=p_membership_id for update;
 if not found then raise exception 'membership_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if v.user_id=auth.uid() then raise exception 'cannot_change_own_membership'; end if;
 if p_role is null or p_role not in ('admin','manager','supervisor','agent') then raise exception 'invalid_role'; end if;
 if not public.can_manage_member_role(v_actor,v.role,p_role) then raise exception 'role_change_not_permitted'; end if;
 if v.role=p_role then raise exception 'no_change'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_memberships set role=p_role,updated_at=now() where id=p_membership_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_user_id,details) values(v.organization_id,auth.uid(),'member_role_changed',v.user_id,jsonb_build_object('from',v.role,'to',p_role));
 perform set_config('corban.membership_rpc','off',true);
end $$;

create or replace function public.set_member_status(p_membership_id uuid, p_status text)
 returns void language plpgsql set search_path='' as $$
declare v public.organization_memberships%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_memberships m where m.id=p_membership_id for update;
 if not found then raise exception 'membership_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if v.user_id=auth.uid() then raise exception 'cannot_change_own_membership'; end if;
 if p_status is null or p_status not in ('active','inactive','revoked') then raise exception 'invalid_status'; end if;
 if not public.can_manage_member_role(v_actor,v.role,v.role) then raise exception 'role_change_not_permitted'; end if;
 if v.status=p_status then raise exception 'no_change'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_memberships set status=p_status,updated_at=now() where id=p_membership_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_user_id,details) values(v.organization_id,auth.uid(),case when p_status='active' then 'member_reactivated' else 'member_deactivated' end,v.user_id,jsonb_build_object('from',v.status,'to',p_status,'role',v.role));
 perform set_config('corban.membership_rpc','off',true);
end $$;

-- service_role only. The caller (server code) passes the identity read from Supabase Auth AFTER checking email_confirmed_at;
-- this function never sees a token. An already active membership is never changed by an invitation.
create or replace function public.accept_organization_invitations(p_user_id uuid, p_email text)
 returns table(organization_id uuid, role text, outcome text) language plpgsql set search_path='' as $$
declare v_email text:=lower(btrim(coalesce(p_email,''))); i public.organization_invitations%rowtype; m public.organization_memberships%rowtype; v_out text;
begin
 if p_user_id is null or v_email='' then raise exception 'invalid_identity'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_invitations x set status='expired',resolved_at=now() where x.email=v_email and x.status='pending' and x.expires_at<=now();
 for i in select * from public.organization_invitations x where x.email=v_email and x.status='pending' order by x.created_at for update loop
  select * into m from public.organization_memberships mm where mm.organization_id=i.organization_id and mm.user_id=p_user_id for update;
  if not found then
   insert into public.organization_memberships(organization_id,user_id,role,status) values(i.organization_id,p_user_id,i.role,'active'); v_out:='joined';
  elsif m.status='active' then v_out:='already_member';
  else
   update public.organization_memberships set role=i.role,status='active',updated_at=now() where id=m.id; v_out:='reactivated';
  end if;
  update public.organization_invitations set status='accepted',resolved_at=now(),accepted_user_id=p_user_id where id=i.id;
  insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_user_id,target_email,details) values(i.organization_id,p_user_id,'invite_accepted',p_user_id,v_email,jsonb_build_object('role',i.role,'outcome',v_out,'invitation_id',i.id));
  organization_id:=i.organization_id; role:=i.role; outcome:=v_out; return next;
 end loop;
 perform set_config('corban.membership_rpc','off',true);
end $$;

revoke all on function public.can_manage_member_role(text,text,text) from public,anon;
revoke all on function public.create_organization_invitation(uuid,text,text) from public,anon;
revoke all on function public.revoke_organization_invitation(uuid) from public,anon;
revoke all on function public.set_member_role(uuid,text) from public,anon;
revoke all on function public.set_member_status(uuid,text) from public,anon;
revoke all on function public.accept_organization_invitations(uuid,text) from public,anon,authenticated;
grant execute on function public.can_manage_member_role(text,text,text) to authenticated,service_role;
grant execute on function public.create_organization_invitation(uuid,text,text) to authenticated;
grant execute on function public.revoke_organization_invitation(uuid) to authenticated;
grant execute on function public.set_member_role(uuid,text) to authenticated;
grant execute on function public.set_member_status(uuid,text) to authenticated;
grant execute on function public.accept_organization_invitations(uuid,text) to service_role;
