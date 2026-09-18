-- Financial reconciliation publisher V0 contract.
do $$
begin
 if to_regprocedure('public.publish_financial_evidence_event(uuid,text,text,numeric,timestamp with time zone,text,text,uuid,uuid,uuid)') is null then raise exception 'evidence_publisher_missing'; end if;
 if to_regprocedure('public.refresh_financial_reconciliation(uuid,text)') is null then raise exception 'reconciliation_refresh_missing'; end if;
 if has_function_privilege('anon','public.refresh_financial_reconciliation(uuid,text)','EXECUTE') then raise exception 'anon_reconciliation_execute'; end if;
 if not has_function_privilege('authenticated','public.refresh_financial_reconciliation(uuid,text)','EXECUTE') then raise exception 'authenticated_reconciliation_execute_missing'; end if;
end $$;
