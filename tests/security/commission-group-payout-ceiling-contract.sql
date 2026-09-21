do $$
declare
  v_col record;
  v_def text;
begin
  select column_name,data_type,is_nullable into v_col
  from information_schema.columns
  where table_schema='public'
    and table_name='commission_groups'
    and column_name='max_received_share_pct';
  if not found then raise exception 'commission_group_limit_missing'; end if;

  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='assert_commission_group_share_within_limit';
  if v_def is null
     or position('commission_group_share_exceeds_limit' in v_def)=0
     or position('max_received_share_pct' in v_def)=0 then
    raise exception 'commission_group_limit_assertion_missing';
  end if;

  if exists(
    select 1 from public.commission_groups
    where calculation_basis<>'percent_of_received_commission'
  ) then raise exception 'legacy_direct_basis_still_present'; end if;

  if not exists(
    select 1 from information_schema.triggers
    where trigger_schema='public'
      and event_object_table='commercial_condition_shares'
      and trigger_name='commercial_condition_shares_15_group_limit'
  ) then raise exception 'condition_share_limit_trigger_missing'; end if;

  if not exists(
    select 1 from information_schema.triggers
    where trigger_schema='public'
      and event_object_table='payout_policy_items'
      and trigger_name='payout_policy_items_15_group_limit'
  ) then raise exception 'policy_share_limit_trigger_missing'; end if;

  if not exists(
    select 1 from information_schema.triggers
    where trigger_schema='public'
      and event_object_table='component_payout_policy_items'
      and trigger_name='component_payout_policy_items_15_group_limit'
  ) then raise exception 'component_share_limit_trigger_missing'; end if;
end $$;
