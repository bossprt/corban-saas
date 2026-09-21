-- Contract: tenant contract type management V1
do $$
declare n integer;
begin
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='contract_types' and column_name='organization_id') then raise exception 'contract_type_org_missing'; end if;
 if not exists(select 1 from information_schema.tables where table_schema='public' and table_name='organization_contract_type_settings') then raise exception 'contract_type_settings_missing'; end if;
 select count(*) into n from public.contract_types where organization_id is null and tech_key in ('novo','refinanciamento','compra_de_divida','portabilidade');
 if n<>4 then raise exception 'global_contract_types_changed'; end if;
 if not exists(select 1 from pg_trigger where tgname='commercial_conditions_01_contract_type_scope') then raise exception 'condition_contract_type_guard_missing'; end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='organization_contract_type_settings' and grantee='anon') then raise exception 'anon_contract_type_setting_grant_found'; end if;
end $$;
