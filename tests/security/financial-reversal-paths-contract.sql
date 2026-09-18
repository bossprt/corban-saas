-- Post-apply STRUCTURAL contract for:
--   20260919_financial_reversal_paths_v1.sql, 20260919_import_batch_adapter_lineage_v1.sql,
--   20260919_restore_rbac_helper_execute_v1.sql, 20260919_fix_digest_search_path_v1.sql.
-- (20260919_revoke_excess_table_privileges_v1 was already applied live by the independent audit; its check is kept.)
-- Read-only. Behavioral coverage lives in financial-reversal-behavior-rollback.sql (rollback-only).
do $$
declare t record;
begin
 if to_regprocedure('public.publish_financial_reversal(uuid,numeric,text,text,text)') is null then raise exception 'reversal_publisher_missing'; end if;
 if has_function_privilege('anon','public.publish_financial_reversal(uuid,numeric,text,text,text)','EXECUTE') then raise exception 'anon_reversal_execute'; end if;
 if not has_function_privilege('authenticated','public.publish_financial_reversal(uuid,numeric,text,text,text)','EXECUTE') then raise exception 'authenticated_reversal_execute_missing'; end if;
 if (select prosecdef from pg_proc where oid='public.publish_financial_reversal(uuid,numeric,text,text,text)'::regprocedure) then raise exception 'reversal_publisher_must_be_invoker'; end if;
 -- partial reversals require that there is NO unique index on reverses_event_id
 if exists(select 1 from pg_indexes where schemaname='public' and tablename='financial_events' and indexdef ilike '%unique%' and indexdef ilike '%reverses_event_id%') then raise exception 'unique_reversal_index_forbids_partial_reversals'; end if;
 if pg_get_functiondef('public.guard_financial_event_insert'::regproc) not like '%pg_advisory_xact_lock%' then raise exception 'reversal_lock_missing'; end if;
 if pg_get_functiondef('public.guard_financial_event_insert'::regproc) not like '%financial_event_type_not_governed%' then raise exception 'ungoverned_event_types_not_blocked'; end if;
 if pg_get_functiondef('public.refresh_financial_reconciliation(uuid,text)'::regprocedure) not like '%-e.amount%' then raise exception 'reconciliation_does_not_net_reversals'; end if;
 if pg_get_functiondef('public.refresh_financial_reconciliation(uuid,text)'::regprocedure) ilike '%organization_memberships%' then raise exception 'reconciliation_resolves_tenant_by_membership'; end if;
 -- attach_import_batch_adapter: batch is tenant authority, definer with pinned search_path, no anon
 if to_regprocedure('public.attach_import_batch_adapter(uuid,text)') is null then raise exception 'attach_adapter_missing'; end if;
 if has_function_privilege('anon','public.attach_import_batch_adapter(uuid,text)','EXECUTE') then raise exception 'anon_attach_execute'; end if;
 if pg_get_functiondef('public.attach_import_batch_adapter(uuid,text)'::regprocedure) ilike '%limit 1%' then raise exception 'attach_uses_limit_1'; end if;
 if not exists(select 1 from pg_proc where oid='public.attach_import_batch_adapter(uuid,text)'::regprocedure and prosecdef and 'search_path=""' = any(proconfig)) then raise exception 'attach_definer_search_path_not_pinned'; end if;
 -- RBAC helper must be callable by authenticated (policies and invoker RPCs evaluate it as the caller)
 if not has_function_privilege('authenticated','public.has_active_organization_role(uuid,text[])','EXECUTE') then raise exception 'rbac_helper_not_executable_by_authenticated'; end if;
 if has_function_privilege('anon','public.has_active_organization_role(uuid,text[])','EXECUTE') then raise exception 'rbac_helper_executable_by_anon'; end if;
 -- pgcrypto digest must be schema-qualified in functions that pin search_path=public
 for t in select p.proname from pg_proc p where p.pronamespace='public'::regnamespace and pg_get_functiondef(p.oid) ~* '[^_.a-z]digest\(' loop
  raise exception 'unqualified_digest_in_%',t.proname;
 end loop;
 for t in select tablename from pg_tables where schemaname='public' loop
  if has_table_privilege('authenticated','public.'||quote_ident(t.tablename),'TRUNCATE') or has_table_privilege('anon','public.'||quote_ident(t.tablename),'TRUNCATE') then raise exception 'truncate_privilege_%',t.tablename; end if;
 end loop;
end $$;
