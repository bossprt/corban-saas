-- Contract for prepared Commercial Network & Channels V0 migration.
do $$
begin
  if to_regclass('public.commercial_entities') is null then raise exception 'commercial_entities_missing'; end if;
  if to_regclass('public.commercial_relationships') is null then raise exception 'commercial_relationships_missing'; end if;
  if to_regclass('public.commercial_channels') is null then raise exception 'commercial_channels_missing'; end if;
  if to_regclass('public.product_table_external_identities') is null then raise exception 'table_external_identities_missing'; end if;
  if to_regclass('public.channel_commission_rule_versions') is null then raise exception 'commission_rules_missing'; end if;
  if to_regclass('public.commission_rule_components') is null then raise exception 'commission_components_missing'; end if;
  if to_regclass('public.network_split_rule_versions') is null then raise exception 'network_split_rules_missing'; end if;
  if to_regclass('public.proposal_external_identities') is null then raise exception 'proposal_external_identities_missing'; end if;
  if to_regclass('public.proposal_commercial_snapshots') is null then raise exception 'proposal_commercial_snapshots_missing'; end if;

  if exists (
    select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name in (
      'commercial_entities','commercial_relationships','commercial_channels',
      'product_table_external_identities','channel_commission_rule_versions',
      'commission_rule_components','network_split_rule_versions',
      'proposal_external_identities','proposal_commercial_snapshots'
    ) and grantee='anon'
  ) then raise exception 'anon_commercial_access_detected'; end if;
end $$;
