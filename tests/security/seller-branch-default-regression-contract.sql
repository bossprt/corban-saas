do $$
declare def text;
begin
 select pg_get_functiondef(p.oid) into def
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='guard_seller_catalog_row';
 if def is null or position('active_matrix_required' in def)=0 or position('branch_type=''matrix''' in def)=0 then
   raise exception 'seller_matrix_default_guard_missing';
 end if;
end $$;