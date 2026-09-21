-- Contract: component-aware commissions V1
do $$
declare n integer;
begin
 select count(*) into n from information_schema.tables where table_schema='public' and table_name in (
  'commission_component_types','commercial_condition_components','component_payout_policies','component_payout_policy_versions','component_payout_policy_items'
 );
 if n<>5 then raise exception 'component_tables_missing'; end if;
 select count(*) into n from public.commission_component_types where tech_key in ('upfront','deferred','bonus_1','bonus_2','bonus_3','plastic','insurance_fixed');
 if n<>7 then raise exception 'component_seed_missing'; end if;
 if not exists(select 1 from pg_proc where proname='replace_commercial_condition_components') then raise exception 'component_replace_rpc_missing'; end if;
 if not exists(select 1 from pg_proc where proname='save_component_payout_policy') then raise exception 'component_policy_rpc_missing'; end if;
 if not exists(select 1 from pg_proc where proname='resolve_component_payout_policy') then raise exception 'component_policy_resolver_missing'; end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name in ('commercial_condition_components','component_payout_policies','component_payout_policy_versions','component_payout_policy_items') and grantee='anon') then raise exception 'anon_component_grant_found'; end if;
end $$;
