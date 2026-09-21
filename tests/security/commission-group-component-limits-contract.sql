do $$
declare def text;
begin
  if to_regclass('public.commission_group_component_limits') is null then
    raise exception 'commission_group_component_limits_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='save_commission_group_configuration';
  if def is null
     or position('commission_group_components_incomplete' in def)=0
     or position('percent_of_received_commission' in def)=0 then
    raise exception 'commission_group_configuration_rpc_incomplete';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_component_payout_group_limit';
  if def is null
     or position('commission_group_component_share_exceeds_limit' in def)=0
     or position('commission_group_direct_component_mode_forbidden' in def)=0 then
    raise exception 'component_limit_guard_incomplete';
  end if;

  if exists(
    select 1 from public.commission_groups
    where calculation_basis<>'percent_of_received_commission'
  ) then raise exception 'non_received_commission_group_exists'; end if;
end $$;
