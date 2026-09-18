-- Expected commission publisher V0 contract.
do $$
begin
 if to_regprocedure('public.publish_expected_commission(uuid)') is null then raise exception 'publisher_missing'; end if;
 if has_function_privilege('anon','public.publish_expected_commission(uuid)','EXECUTE') then raise exception 'anon_execute'; end if;
 if not has_function_privilege('authenticated','public.publish_expected_commission(uuid)','EXECUTE') then raise exception 'authenticated_execute_missing'; end if;
 if not exists(select 1 from pg_proc where oid='public.publish_expected_commission(uuid)'::regprocedure and prosecdef=false) then raise exception 'publisher_must_be_security_invoker'; end if;
end $$;
