-- Seller access bootstrap V1 contract
do $$
declare def text;
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='organization_invitations'
      and column_name='seller_id'
  ) then raise exception 'seller_invitation_link_missing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='create_seller_with_access';
  if def is null then raise exception 'create_seller_with_access_missing'; end if;
  if position('create_organization_invitation' in def)=0
     or position('''agent''' in def)=0
     or position('commercial_sellers' in def)=0 then
    raise exception 'seller_access_bootstrap_incomplete';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='accept_organization_invitations';
  if def is null
     or position('seller_id' in def)=0
     or position('corban.seller_access_rpc' in def)=0 then
    raise exception 'invitation_accept_does_not_bind_seller';
  end if;

  if has_function_privilege('anon','public.create_seller_with_access(uuid,text,text,text,uuid,uuid,text)','EXECUTE') then
    raise exception 'anon_can_create_seller_with_access';
  end if;

  if not exists(
    select 1 from pg_constraint
    where conrelid='public.organization_admin_events'::regclass
      and conname='organization_admin_events_event_type_check'
      and pg_get_constraintdef(oid) ilike '%seller_created%'
      and pg_get_constraintdef(oid) ilike '%seller_user_binding_updated%'
      and pg_get_constraintdef(oid) ilike '%seller_supervision_updated%'
  ) then raise exception 'seller_audit_event_types_missing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='set_seller_user';
  if def is null
     or position('active_agent_membership_required' in def)=0
     or position('corban.membership_rpc' in def)=0 then
    raise exception 'seller_user_binding_not_governed';
  end if;
end $$;
