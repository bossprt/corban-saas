-- Post-apply contract for 20260919_financial_reversal_paths_v1.sql and 20260919_revoke_excess_table_privileges_v1.sql.
do $$
declare t record;
begin
 if to_regprocedure('public.publish_financial_reversal(uuid,numeric,text,text,text)') is null then raise exception 'reversal_publisher_missing'; end if;
 if has_function_privilege('anon','public.publish_financial_reversal(uuid,numeric,text,text,text)','EXECUTE') then raise exception 'anon_reversal_execute'; end if;
 if not has_function_privilege('authenticated','public.publish_financial_reversal(uuid,numeric,text,text,text)','EXECUTE') then raise exception 'authenticated_reversal_execute_missing'; end if;
 if (select prosecdef from pg_proc where oid='public.publish_financial_reversal(uuid,numeric,text,text,text)'::regprocedure) then raise exception 'reversal_publisher_must_be_invoker'; end if;
 if not exists(select 1 from pg_indexes where indexname='financial_events_single_reversal_uidx') then raise exception 'single_reversal_index_missing'; end if;
 if pg_get_functiondef('public.guard_financial_event_insert'::regproc) not like '%financial_reversal_requires_governed_rpc%' then raise exception 'reversal_guard_missing'; end if;
 if pg_get_functiondef('public.refresh_financial_reconciliation(uuid,text)'::regprocedure) not like '%-e.amount%' then raise exception 'reconciliation_does_not_net_reversals'; end if;
 for t in select tablename from pg_tables where schemaname='public' loop
  if has_table_privilege('authenticated','public.'||quote_ident(t.tablename),'TRUNCATE') or has_table_privilege('anon','public.'||quote_ident(t.tablename),'TRUNCATE') then raise exception 'truncate_privilege_%',t.tablename; end if;
 end loop;
end $$;
