-- Seller/SUB proposal snapshot V1 security/integrity contract.
do $$
declare
  def text;
  n integer;
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='proposals_v2' and column_name='seller_id'
  ) then raise exception 'proposal_seller_id_missing'; end if;

  select count(*) into n
  from information_schema.columns
  where table_schema='public'
    and table_name='proposal_commercial_component_snapshots'
    and column_name in ('seller_id','seller_sub_rule_version_id','seller_sub_share_pct','seller_company_share_pct');
  if n<>4 then raise exception 'seller_snapshot_columns_missing'; end if;

  if exists(
    select 1 from public.proposal_commercial_component_snapshots
    where seller_sub_share_pct<0 or seller_sub_share_pct>100
       or seller_company_share_pct<0 or seller_company_share_pct>100
       or seller_sub_share_pct+seller_company_share_pct<>100
  ) then raise exception 'seller_share_invariant_failed'; end if;

  if exists(
    select 1 from public.proposal_commercial_component_snapshots
    where seller_sub_rule_version_id is null
      and (seller_sub_share_pct<>0 or seller_company_share_pct<>100)
  ) then raise exception 'unbacked_seller_share_found'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='assign_proposal_seller';
  if def is null then raise exception 'assign_proposal_seller_missing'; end if;
  if position('proposal_seller_rpc' in def)=0
     or position('proposal_commercial_route_already_frozen' in def)=0
     or position('active_seller_not_found' in def)=0 then
    raise exception 'seller_assignment_governance_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='freeze_proposal_commercial_route';
  if def is null
     or position('published_sub_rule_required_for_component' in def)=0
     or position('seller_company_share_pct' in def)=0
     or position('seller_sub_rule_version_id' in def)=0 then
    raise exception 'seller_sub_freeze_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='publish_expected_commission';
  if def is null
     or position('v_cs.seller_company_share_pct' in def)=0
     or position('tenant_before_seller_amount' in def)=0
     or position('company_expected_amount' in def)=0 then
    raise exception 'seller_company_expected_math_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='guard_proposal_write';
  if def is null
     or position('proposal_seller_change_requires_governed_rpc' in def)=0
     or position('proposal_seller_is_frozen' in def)=0 then
    raise exception 'proposal_seller_write_guard_missing';
  end if;

  if has_function_privilege('anon','public.assign_proposal_seller(uuid,uuid)','EXECUTE') then
    raise exception 'anon_can_assign_seller';
  end if;
  if not has_function_privilege('authenticated','public.assign_proposal_seller(uuid,uuid)','EXECUTE') then
    raise exception 'authenticated_cannot_call_governed_seller_assignment';
  end if;
  if has_function_privilege('anon','public.publish_expected_commission(uuid)','EXECUTE') then
    raise exception 'anon_can_publish_expected_commission';
  end if;
end $$;
