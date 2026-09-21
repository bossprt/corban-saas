do $$
declare n integer;
begin
 select count(*) into n from pg_indexes
 where schemaname='public' and indexname in (
  'seller_groups_created_by_idx','commercial_sellers_created_by_idx','seller_sub_rule_versions_created_by_idx',
  'commercial_factor_profiles_agreement_idx','commercial_factor_profiles_table_idx','commercial_factor_profiles_contract_type_idx',
  'commercial_factor_profiles_created_by_idx','commercial_factor_batches_import_batch_idx','commercial_factor_batches_created_by_idx'
 );
 if n<>9 then raise exception 'post_wave_fk_indexes_missing'; end if;
end $$;
