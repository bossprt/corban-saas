-- CORBAN OS — Seller access bootstrap V1
-- PREPARED ONLY. New seller profile/access workflow; requires explicit Human Gate before LIVE apply.

alter table public.organization_invitations
  add column seller_id uuid;

alter table public.organization_invitations
  add constraint organization_invitations_org_seller_fk
  foreign key (organization_id,seller_id)
  references public.commercial_sellers(organization_id,id)
  on delete restrict;

create unique index organization_invitations_pending_seller_key
  on public.organization_invitations(organization_id,seller_id)
  where seller_id is not null and status='pending';


alter table public.organization_admin_events
  drop constraint organization_admin_events_event_type_check;

alter table public.organization_admin_events
  add constraint organization_admin_events_event_type_check
  check (event_type in (
    'invite_created',
    'invite_revoked',
    'invite_accepted',
    'member_role_changed',
    'member_deactivated',
    'member_reactivated',
    'seller_created',
    'seller_user_binding_updated',
    'seller_supervision_updated'
  ));

create or replace function public.create_seller_with_access(
  p_org uuid,
  p_name text,
  p_seller_category text,
  p_tax_id text,
  p_seller_group_id uuid,
  p_commission_group_id uuid,
  p_email text default null
)
returns table(seller_id uuid, invitation_id uuid)
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_actor text;
  v_name text:=btrim(coalesce(p_name,''));
  v_tax text:=nullif(regexp_replace(coalesce(p_tax_id,''),'[^0-9]','','g'),'');
  v_email text:=nullif(lower(btrim(coalesce(p_email,''))),'');
  v_seller uuid;
  v_inv uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  v_actor:=private.caller_role_in(p_org);
  if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;

  if length(v_name) not between 1 and 160 then raise exception 'invalid_seller_name'; end if;
  if p_seller_category not in ('pf','pj','sub') then raise exception 'invalid_seller_category'; end if;
  if v_tax is not null and length(v_tax) not in (11,14) then raise exception 'invalid_seller_tax_id'; end if;

  if not exists(
    select 1 from public.seller_groups g
    where g.organization_id=p_org and g.id=p_seller_group_id and g.is_active
  ) then raise exception 'active_seller_group_required'; end if;

  if not exists(
    select 1 from public.commission_groups g
    where g.organization_id=p_org and g.id=p_commission_group_id and g.is_active
  ) then raise exception 'active_commission_group_required'; end if;

  if v_email is not null and (
    length(v_email) not between 3 and 254
    or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$'
  ) then raise exception 'invalid_email'; end if;

  insert into public.commercial_sellers(
    organization_id,name,seller_category,tax_id,seller_group_id,commission_group_id
  ) values(
    p_org,v_name,p_seller_category,v_tax,p_seller_group_id,p_commission_group_id
  )
  returning id into v_seller;

  if v_email is not null then
    v_inv:=public.create_organization_invitation(p_org,v_email,'agent');
    perform set_config('corban.membership_rpc','on',true);
    update public.organization_invitations i
    set seller_id=v_seller
    where i.id=v_inv and i.organization_id=p_org;
    perform set_config('corban.membership_rpc','off',true);
  end if;

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_email,details
  ) values(
    p_org,auth.uid(),'seller_created',v_email,
    jsonb_build_object(
      'seller_id',v_seller,
      'seller_category',p_seller_category,
      'seller_group_id',p_seller_group_id,
      'commission_group_id',p_commission_group_id,
      'access_invitation_id',v_inv
    )
  );
  perform set_config('corban.membership_rpc','off',true);

  seller_id:=v_seller;
  invitation_id:=v_inv;
  return next;
end
$$;

create or replace function public.accept_organization_invitations(p_user_id uuid,p_email text)
returns table(organization_id uuid,role text,outcome text)
language plpgsql
set search_path=''
as $$
declare
  v_email text:=lower(btrim(coalesce(p_email,'')));
  i public.organization_invitations%rowtype;
  m public.organization_memberships%rowtype;
  v_out text;
begin
  if p_user_id is null or v_email='' then raise exception 'invalid_identity'; end if;

  perform set_config('corban.membership_rpc','on',true);
  update public.organization_invitations x
  set status='expired',resolved_at=now()
  where x.email=v_email and x.status='pending' and x.expires_at<=now();

  for i in
    select * from public.organization_invitations x
    where x.email=v_email and x.status='pending'
    order by x.created_at
    for update
  loop
    select * into m
    from public.organization_memberships mm
    where mm.organization_id=i.organization_id and mm.user_id=p_user_id
    for update;

    if not found then
      insert into public.organization_memberships(organization_id,user_id,role,status)
      values(i.organization_id,p_user_id,i.role,'active');
      v_out:='joined';
    elsif m.status='active' then
      v_out:='already_member';
    else
      update public.organization_memberships
      set role=i.role,status='active',updated_at=now()
      where id=m.id;
      v_out:='reactivated';
    end if;

    if i.seller_id is not null then
      if i.role <> 'agent' then raise exception 'seller_invitation_must_be_agent'; end if;
      if m.id is not null and m.status='active' and m.role<>'agent' then
        raise exception 'seller_access_requires_agent_role';
      end if;
      if exists(
        select 1 from public.commercial_sellers s
        where s.organization_id=i.organization_id
          and s.id=i.seller_id
          and s.user_id is not null
          and s.user_id<>p_user_id
      ) then raise exception 'seller_already_bound_to_other_user'; end if;

      perform set_config('corban.seller_access_rpc','on',true);
      update public.commercial_sellers
      set user_id=p_user_id,updated_at=now()
      where organization_id=i.organization_id
        and id=i.seller_id;
      perform set_config('corban.seller_access_rpc','off',true);
    end if;

    update public.organization_invitations
    set status='accepted',resolved_at=now(),accepted_user_id=p_user_id
    where id=i.id;

    insert into public.organization_admin_events(
      organization_id,actor_user_id,event_type,target_user_id,target_email,details
    ) values(
      i.organization_id,p_user_id,'invite_accepted',p_user_id,v_email,
      jsonb_build_object(
        'role',i.role,
        'outcome',v_out,
        'invitation_id',i.id,
        'seller_id',i.seller_id
      )
    );

    organization_id:=i.organization_id;
    role:=i.role;
    outcome:=v_out;
    return next;
  end loop;

  perform set_config('corban.membership_rpc','off',true);
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
as $
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
      and m.role='agent'
      and m.status='active'
  ) then raise exception 'active_agent_membership_required'; end if;

  perform set_config('corban.seller_access_rpc','on',true);
  update public.commercial_sellers
  set user_id=p_user_id,updated_at=now()
  where organization_id=v_org and id=p_seller_id;
  perform set_config('corban.seller_access_rpc','off',true);

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_user_binding_updated',p_user_id,
    jsonb_build_object('seller_id',p_seller_id,'bound_user_id',p_user_id)
  );
  perform set_config('corban.membership_rpc','off',true);

  return p_seller_id;
end
$;

create or replace function public.set_seller_supervision(
  p_seller_id uuid,
  p_supervisor_user_id uuid,
  p_active boolean default true
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $
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

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_supervision_updated',p_supervisor_user_id,
    jsonb_build_object('seller_id',p_seller_id,'active',coalesce(p_active,true))
  );
  perform set_config('corban.membership_rpc','off',true);

  return v_id;
end
$;

revoke all on function public.create_seller_with_access(uuid,text,text,text,uuid,uuid,text) from public,anon;
grant execute on function public.create_seller_with_access(uuid,text,text,text,uuid,uuid,text) to authenticated;
revoke all on function public.set_seller_user(uuid,uuid) from public,anon;
grant execute on function public.set_seller_user(uuid,uuid) to authenticated;
revoke all on function public.set_seller_supervision(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_seller_supervision(uuid,uuid,boolean) to authenticated;
