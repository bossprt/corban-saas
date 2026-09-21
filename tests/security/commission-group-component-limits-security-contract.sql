do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='save_commission_group_configuration';
  if def is null or position('SECURITY DEFINER' in upper(def))>0 then
    raise exception 'commission_group_config_still_security_definer';
  end if;
  if position('corban.commission_group_config_rpc' in def)=0 then
    raise exception 'commission_group_config_gate_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_commission_group_component_limit_write';
  if def is null or position('commission_group_component_write_requires_governed_rpc' in def)=0 then
    raise exception 'commission_group_component_write_guard_missing';
  end if;
end $$;