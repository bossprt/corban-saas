-- Seller catalog shared trigger regression contract V1
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_seller_catalog_row';

  if def is null then raise exception 'guard_missing'; end if;
  if position('new.user_id' in lower(def))>0 or position('old.user_id' in lower(def))>0 then
    raise exception 'shared_trigger_direct_user_id_dereference_present';
  end if;
  if position('to_jsonb(new)' in lower(def))=0 then
    raise exception 'shared_trigger_safe_user_id_lookup_missing';
  end if;
  if position('seller_user_binding_requires_governed_rpc' in def)=0 then
    raise exception 'seller_user_binding_guard_lost';
  end if;
end $$;
