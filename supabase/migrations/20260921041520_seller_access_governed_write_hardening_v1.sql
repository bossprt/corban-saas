-- CORBAN OS — Seller access governed write hardening V1
-- Standing Owner authorization: same seller commission visibility rule.
-- Direct Data API writes to seller user binding/supervision must not bypass governed RPCs/audit.

create or replace function public.guard_seller_catalog_row()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then
      new.created_by:=auth.uid();
      if tg_table_name='commercial_sellers'
         and new.user_id is not null
         and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
        raise exception 'seller_user_binding_requires_governed_rpc';
      end if;
    end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'seller_identity_is_immutable'; end if;

    if tg_table_name='commercial_sellers'
       and new.user_id is distinct from old.user_id
       and current_user in ('authenticated','anon')
       and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
      raise exception 'seller_user_binding_requires_governed_rpc';
    end if;

    new.updated_at:=now();
  end if;
  return new;
end
$$;

create or replace function public.guard_seller_supervision()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_role text;
  v_status text;
begin
  if tg_op='DELETE' then raise exception 'seller_supervision_delete_forbidden'; end if;

  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
    raise exception 'seller_supervision_write_requires_governed_rpc';
  end if;

  select m.role,m.status into v_role,v_status
  from public.organization_memberships m
  where m.organization_id=new.organization_id
    and m.user_id=new.supervisor_user_id;

  if v_role is distinct from 'supervisor' or v_status is distinct from 'active' then
    raise exception 'active_supervisor_membership_required';
  end if;

  if not exists(
    select 1 from public.commercial_sellers s
    where s.organization_id=new.organization_id
      and s.id=new.seller_id
      and s.is_active
  ) then
    raise exception 'active_seller_required';
  end if;

  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    new.updated_by:=new.created_by;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.supervisor_user_id is distinct from old.supervisor_user_id
       or new.seller_id is distinct from old.seller_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
    then raise exception 'seller_supervision_identity_is_immutable'; end if;
    if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
    new.updated_at:=now();
  end if;

  return new;
end
$$;

create or replace function public.set_seller_user(
  p_seller_id uuid,
  p_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id
  for update;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if p_user_id is not null and not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_user_id
      and m.status='active'
  ) then raise exception 'active_membership_required'; end if;

  perform set_config('corban.seller_access_rpc','on',true);
  update public.commercial_sellers
  set user_id=p_user_id,updated_at=now()
  where organization_id=v_org and id=p_seller_id;
  perform set_config('corban.seller_access_rpc','off',true);

  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_user_binding_updated',p_user_id,
    jsonb_build_object('seller_id',p_seller_id,'bound_user_id',p_user_id)
  );

  return p_seller_id;
end
$$;

create or replace function public.set_seller_supervision(
  p_seller_id uuid,
  p_supervisor_user_id uuid,
  p_active boolean default true
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_org uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_supervisor_user_id
      and m.role='supervisor'
      and m.status='active'
  ) then raise exception 'active_supervisor_membership_required'; end if;

  perform set_config('corban.seller_access_rpc','on',true);
  insert into public.seller_supervisions(
    organization_id,supervisor_user_id,seller_id,is_active,created_by,updated_by
  ) values(
    v_org,p_supervisor_user_id,p_seller_id,coalesce(p_active,true),auth.uid(),auth.uid()
  )
  on conflict(organization_id,supervisor_user_id,seller_id)
  do update set is_active=excluded.is_active,updated_by=auth.uid(),updated_at=now()
  returning id into v_id;
  perform set_config('corban.seller_access_rpc','off',true);

  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_supervision_updated',p_supervisor_user_id,
    jsonb_build_object('seller_id',p_seller_id,'active',coalesce(p_active,true))
  );

  return v_id;
end
$$;

revoke all on function public.guard_seller_catalog_row() from public,anon,authenticated;
revoke all on function public.guard_seller_supervision() from public,anon,authenticated;

revoke all on function public.set_seller_user(uuid,uuid) from public,anon;
grant execute on function public.set_seller_user(uuid,uuid) to authenticated;
revoke all on function public.set_seller_supervision(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_seller_supervision(uuid,uuid,boolean) to authenticated;
