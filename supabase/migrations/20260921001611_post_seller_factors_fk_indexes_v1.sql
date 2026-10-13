-- CORBAN OS — Post Seller/Factors FK indexes V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Performance-only, additive indexes for foreign keys introduced in 20261007/20261008.

create index if not exists seller_groups_created_by_idx
  on public.seller_groups(created_by) where created_by is not null;

create index if not exists commercial_sellers_created_by_idx
  on public.commercial_sellers(created_by) where created_by is not null;

create index if not exists seller_sub_rule_versions_created_by_idx
  on public.seller_sub_rule_versions(created_by) where created_by is not null;

create index if not exists commercial_factor_profiles_agreement_idx
  on public.commercial_factor_profiles(organization_id,org_agreement_id) where org_agreement_id is not null;

create index if not exists commercial_factor_profiles_table_idx
  on public.commercial_factor_profiles(organization_id,product_table_id) where product_table_id is not null;

create index if not exists commercial_factor_profiles_contract_type_idx
  on public.commercial_factor_profiles(contract_type_id) where contract_type_id is not null;

create index if not exists commercial_factor_profiles_created_by_idx
  on public.commercial_factor_profiles(created_by) where created_by is not null;

create index if not exists commercial_factor_batches_import_batch_idx
  on public.commercial_factor_batches(import_batch_id) where import_batch_id is not null;

create index if not exists commercial_factor_batches_created_by_idx
  on public.commercial_factor_batches(created_by) where created_by is not null;
