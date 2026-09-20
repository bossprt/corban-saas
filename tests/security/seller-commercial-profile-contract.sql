-- Contract for seller_commercial_profile_v1. Run after migration or inside a rollback harness.
do $$
declare n integer;
begin
  select count(*) into n from information_schema.tables where table_schema='public' and table_name in ('seller_groups','commercial_sellers','seller_sub_rule_versions');
  if n<>3 then raise exception 'seller_tables_missing'; end if;

  if not exists(select 1 from pg_proc where proname='publish_seller_sub_rule') then raise exception 'publish_seller_sub_rule_missing'; end if;
  if not exists(select 1 from pg_proc where proname='resolve_seller_sub_rule') then raise exception 'resolve_seller_sub_rule_missing'; end if;

  if exists(
    select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name in ('seller_groups','commercial_sellers','seller_sub_rule_versions')
      and grantee='anon'
  ) then raise exception 'anon_seller_grant_found'; end if;

  select count(*) into n
  from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
  where ns.nspname='public' and c.relname in ('seller_groups','commercial_sellers','seller_sub_rule_versions') and c.relrowsecurity;
  if n<>3 then raise exception 'seller_rls_not_enabled'; end if;
end $$;
