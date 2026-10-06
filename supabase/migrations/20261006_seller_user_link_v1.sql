-- A seller record can be linked to a team member of any role (owner request 06/10/2026). A manager or an administrator
-- who also sells is the same person as their seller record: linking makes their production count in their goal and as
-- theirs, without changing their role or what they see. Before, only an agent could be linked and the seller screen
-- could only create a new portal login, which a member's e-mail rightly refuses (one person, one login).
--   * set_seller_user: the user must be an active member (agent, supervisor, manager or admin) of the seller's company
--     and not linked to another seller of that company ('user_already_linked'); admin or manager only; audited as before.
-- A linked person is the holder of the seller's payout account, so they cannot register payments to themselves.

create or replace function public.set_seller_user(p_seller_id uuid, p_user_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $function$
declare
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id = p_seller_id
  for update;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org, array['admin', 'manager']) then
    raise exception 'forbidden';
  end if;

  if p_user_id is not null and not exists (
    select 1 from public.organization_memberships m
    where m.organization_id = v_org
      and m.user_id = p_user_id
      and m.role in ('agent', 'supervisor', 'manager', 'admin')
      and m.status = 'active'
  ) then raise exception 'active_membership_required'; end if;

  if p_user_id is not null and exists (
    select 1 from public.commercial_sellers s
    where s.organization_id = v_org and s.user_id = p_user_id and s.id <> p_seller_id
  ) then raise exception 'user_already_linked'; end if;

  perform set_config('corban.seller_access_rpc', 'on', true);
  update public.commercial_sellers
  set user_id = p_user_id, updated_at = now()
  where organization_id = v_org and id = p_seller_id;
  perform set_config('corban.seller_access_rpc', 'off', true);

  perform set_config('corban.membership_rpc', 'on', true);
  insert into public.organization_admin_events(
    organization_id, actor_user_id, event_type, target_user_id, details
  ) values (
    v_org, auth.uid(), 'seller_user_binding_updated', p_user_id,
    jsonb_build_object('seller_id', p_seller_id, 'bound_user_id', p_user_id)
  );
  perform set_config('corban.membership_rpc', 'off', true);

  return p_seller_id;
end
$function$;
