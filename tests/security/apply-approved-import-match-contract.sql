-- Contract: approved import match application is exposed only to authenticated roles and lineage table is tenant-RLS protected.
do $$
begin
 if to_regclass('public.import_applied_decisions') is null then raise exception 'applied_decisions_missing'; end if;
 if to_regprocedure('public.apply_approved_import_match(uuid)') is null then raise exception 'apply_rpc_missing'; end if;
 if has_function_privilege('anon','public.apply_approved_import_match(uuid)','EXECUTE') then raise exception 'anon_execute_detected'; end if;
 if not has_function_privilege('authenticated','public.apply_approved_import_match(uuid)','EXECUTE') then raise exception 'authenticated_execute_missing'; end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='import_applied_decisions' and policyname='import_applied_decisions_select_member') then raise exception 'tenant_select_policy_missing'; end if;
end $$;
