-- Seller operations identity V1 contract
do $$
declare def text;
begin
  if to_regclass('public.organization_branches') is null then raise exception 'branches_missing'; end if;
  if to_regclass('public.seller_bank_aliases') is null then raise exception 'seller_bank_aliases_missing'; end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='commercial_sellers'
      and column_name='commission_payment_frequency'
  ) then raise exception 'seller_payment_frequency_missing'; end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='commercial_sellers'
      and column_name='branch_id'
  ) then raise exception 'seller_branch_missing'; end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='import_normalized_rows'
      and column_name='producer_external_user'
  ) then raise exception 'import_external_user_missing'; end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='import_normalized_rows'
      and column_name='resolved_seller_id'
  ) then raise exception 'import_resolved_seller_missing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='ingest_normalized_import_batch';
  if def is null
     or position('producerExternalUser' in def)=0
     or position('resolve_seller_bank_alias' in def)=0 then
    raise exception 'import_alias_resolution_not_integrated';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='generate_import_match_candidates';
  if def is null
     or position('resolved_seller_id' in def)=0
     or position('seller_alias_resolved' in def)=0 then
    raise exception 'match_candidate_seller_resolution_missing';
  end if;

  if has_function_privilege('anon','public.resolve_seller_bank_alias(uuid,text,text)','EXECUTE') then
    raise exception 'anon_can_resolve_seller_alias';
  end if;
end $$;
