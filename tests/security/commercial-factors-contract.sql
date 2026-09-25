-- Contract for commercial_factors_v1. Run after migration or inside a rollback harness.
do $$
declare n integer;
begin
  select count(*) into n from information_schema.tables where table_schema='public' and table_name in ('commercial_factor_profiles','commercial_factor_batches','commercial_factor_entries');
  if n<>3 then raise exception 'factor_tables_missing'; end if;

  if not exists(select 1 from pg_proc where proname='publish_commercial_factor_batch') then raise exception 'factor_publish_rpc_missing'; end if;
  if not exists(select 1 from pg_proc where proname='resolve_commercial_factor') then raise exception 'factor_resolver_missing'; end if;

  if exists(
    select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name in ('commercial_factor_profiles','commercial_factor_batches','commercial_factor_entries')
      and grantee='anon'
  ) then raise exception 'anon_factor_grant_found'; end if;

  select count(*) into n
  from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
  where ns.nspname='public' and c.relname in ('commercial_factor_profiles','commercial_factor_batches','commercial_factor_entries') and c.relrowsecurity;
  if n<>3 then raise exception 'factor_rls_not_enabled'; end if;
end $$;
