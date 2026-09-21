do $$
declare n integer;
begin
 if not exists(select 1 from information_schema.tables where table_schema='public' and table_name='commercial_condition_component_policy') then raise exception 'condition_component_policy_missing'; end if;
 if not exists(select 1 from pg_proc where proname='import_smart_commercial_rows') then raise exception 'smart_import_rpc_missing'; end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='commercial_condition_component_policy' and grantee='anon') then raise exception 'anon_condition_component_policy_grant'; end if;
 select count(*) into n from pg_policies where schemaname='public' and tablename='commercial_condition_component_policy';
 if n<3 then raise exception 'condition_component_policy_rls_missing'; end if;
end $$;
