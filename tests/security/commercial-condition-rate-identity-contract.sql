do $$
declare def text;
begin
  if exists(
    select 1 from pg_constraint
    where conrelid='public.commercial_conditions'::regclass
      and conname='commercial_conditions_product_table_version_id_contract_typ_key'
  ) then raise exception 'legacy_condition_uniqueness_still_present'; end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='commercial_conditions'
      and indexname='commercial_conditions_version_contract_term_rate_coeff_key'
  ) then raise exception 'rate_aware_condition_unique_index_missing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='import_commercial_conditions';

  if def is null
     or position('c.rate is not distinct from v_rate' in lower(def))=0
     or position('c.coefficient is not distinct from v_coefficient' in lower(def))=0
     or position('coalesce(v_coefficient::text' in lower(def))=0
  then raise exception 'bulk_import_not_rate_aware'; end if;
end $$;