-- Team access created by the admin with e-mail and password (owner decision 29/09/2026). Invitation e-mails failed in
-- production and made the manager depend on e-mail delivery and on the employee finishing a sign-up.
--
-- The seller portal access (role Corretor) follows the same path: invite_seller_to_portal, then the login with a password.
--
-- The server creates (or completes) the login with the service role, but only after these functions, called with the
-- manager's own session, decide it is allowed:
--   * prepare_member_access: same rules as an invitation (admin or manager, only roles the caller may assign), creates the
--     invitation that the service-role accept turns into the membership, and refuses an e-mail that belongs to anyone with
--     access to another company, to a platform administrator, or to someone already active here.
--   * authorize_member_password / record_member_password_set: a new password for a member whose only company is this one,
--     never for the caller, only for roles the caller may manage.
-- Passwords never reach the database functions; Supabase Auth stores them.

alter table public.organization_admin_events drop constraint organization_admin_events_event_type_check;
alter table public.organization_admin_events add constraint organization_admin_events_event_type_check check (event_type = any (array[
  'invite_created', 'invite_revoked', 'invite_accepted', 'member_role_changed', 'member_deactivated', 'member_reactivated',
  'seller_created', 'seller_user_binding_updated', 'seller_supervision_updated', 'role_created', 'role_updated',
  'member_access_role_changed', 'member_hierarchy_changed', 'api_key_created', 'api_key_revoked',
  'member_password_set'
]));

-- Whether a login (by e-mail) may be completed or changed by a manager of p_org: it must not reach anything outside p_org.
create or replace function private.login_only_in(p_org uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select not exists (select 1 from public.organization_memberships m where m.user_id = p_user and m.organization_id <> p_org)
     and not exists (select 1 from public.platform_administrators pa where pa.user_id = p_user)
$$;
revoke all on function private.login_only_in(uuid, uuid) from public, anon, authenticated;

-- The existing login behind an e-mail, if any, when a manager of p_org may complete it (set its password): nobody already in
-- this company, never the caller, never a login that reaches another company or the platform. Used by the team screen and
-- by the seller portal access.
create or replace function public.check_login_email(p_org uuid, p_email text)
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_actor text;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  v_actor := private.caller_role_in(p_org);
  if v_actor is null or v_actor not in ('admin', 'manager') then raise exception 'not_authorized'; end if;
  if length(v_email) not between 3 and 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then raise exception 'invalid_email'; end if;
  select u.id into v_user from auth.users u where lower(u.email) = v_email;
  if v_user is null then return null; end if;
  if v_user = auth.uid() then raise exception 'cannot_change_own_membership'; end if;
  if exists (select 1 from public.organization_memberships m where m.organization_id = p_org and m.user_id = v_user) then
    raise exception 'already_member';
  end if;
  if not private.login_only_in(p_org, v_user) then raise exception 'email_has_other_access'; end if;
  return v_user;
end
$$;
revoke all on function public.check_login_email(uuid, text) from public, anon;
grant execute on function public.check_login_email(uuid, text) to authenticated;

create or replace function public.prepare_member_access(p_org uuid, p_email text, p_role text)
returns table (invitation_id uuid, existing_user_id uuid)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_actor text;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user uuid;
  v_invitation uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  v_actor := private.caller_role_in(p_org);
  if v_actor is null or v_actor not in ('admin', 'manager') then raise exception 'not_authorized'; end if;
  if p_role is null or p_role not in ('admin', 'manager', 'supervisor', 'agent') then raise exception 'invalid_role'; end if;
  if not public.can_manage_member_role(v_actor, null, p_role) then raise exception 'role_change_not_permitted'; end if;
  if length(v_email) not between 3 and 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then raise exception 'invalid_email'; end if;

  v_user := public.check_login_email(p_org, v_email);

  perform set_config('corban.membership_rpc', 'on', true);
  -- A pending invitation for this e-mail is replaced by this one (its role may differ); history keeps both.
  update public.organization_invitations i set status = 'revoked', resolved_at = now()
   where i.organization_id = p_org and i.email = v_email and i.status = 'pending';
  insert into public.organization_invitations (organization_id, email, role, invited_by)
  values (p_org, v_email, p_role, auth.uid()) returning id into v_invitation;
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, target_email, details)
  values (p_org, auth.uid(), 'invite_created', v_email, jsonb_build_object('role', p_role, 'invitation_id', v_invitation, 'with_password', true));
  perform set_config('corban.membership_rpc', 'off', true);

  invitation_id := v_invitation;
  existing_user_id := v_user;
  return next;
end
$$;
revoke all on function public.prepare_member_access(uuid, text, text) from public, anon;
grant execute on function public.prepare_member_access(uuid, text, text) to authenticated;

create or replace function public.authorize_member_password(p_membership_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  m public.organization_memberships%rowtype;
  v_actor text;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into m from public.organization_memberships x where x.id = p_membership_id;
  if not found then raise exception 'membership_not_found'; end if;
  v_actor := private.caller_role_in(m.organization_id);
  if v_actor is null or v_actor not in ('admin', 'manager') then raise exception 'not_authorized'; end if;
  if m.user_id = auth.uid() then raise exception 'cannot_change_own_membership'; end if;
  if not public.can_manage_member_role(v_actor, m.role, m.role) then raise exception 'role_change_not_permitted'; end if;
  if not private.login_only_in(m.organization_id, m.user_id) then raise exception 'email_has_other_access'; end if;
  return m.user_id;
end
$$;
revoke all on function public.authorize_member_password(uuid) from public, anon;
grant execute on function public.authorize_member_password(uuid) to authenticated;

create or replace function public.record_member_password_set(p_membership_id uuid, p_must_change boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  m public.organization_memberships%rowtype;
begin
  -- Same checks as the authorization; written only after Auth accepted the new password.
  perform public.authorize_member_password(p_membership_id);
  select * into m from public.organization_memberships x where x.id = p_membership_id;
  perform set_config('corban.membership_rpc', 'on', true);
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, target_user_id, details)
  values (m.organization_id, auth.uid(), 'member_password_set', m.user_id, jsonb_build_object('must_change', coalesce(p_must_change, true)));
  perform set_config('corban.membership_rpc', 'off', true);
end
$$;
revoke all on function public.record_member_password_set(uuid, boolean) from public, anon;
grant execute on function public.record_member_password_set(uuid, boolean) to authenticated;
