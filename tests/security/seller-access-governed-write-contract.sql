-- Seller access governed write hardening V1 contract
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_seller_catalog_row';
  if def is null
     or position('seller_user_binding_requires_governed_rpc' in def)=0
     or position('corban.seller_access_rpc' in def)=0 then
    raise exception 'seller_user_binding_direct_write_not_guarded';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_seller_supervision';
  if def is null
     or position('seller_supervision_write_requires_governed_rpc' in def)=0
     or position('corban.seller_access_rpc' in def)=0 then
    raise exception 'seller_supervision_direct_write_not_guarded';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='set_seller_user';
  if def is null
     or position('set_config(''corban.seller_access_rpc'',''on'',true)' in replace(def,' ',''))=0 then
    raise exception 'seller_user_rpc_does_not_open_guard';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='set_seller_supervision';
  if def is null
     or position('set_config(''corban.seller_access_rpc'',''on'',true)' in replace(def,' ',''))=0 then
    raise exception 'seller_supervision_rpc_does_not_open_guard';
  end if;

  if has_function_privilege('anon','public.set_seller_user(uuid,uuid)','EXECUTE')
     or has_function_privilege('anon','public.set_seller_supervision(uuid,uuid,boolean)','EXECUTE') then
    raise exception 'anon_seller_access_rpc_execute';
  end if;
end $$;
