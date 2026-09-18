-- Read-only inventory contract (post-apply of 20260919_rbac_helper_security_invoker_v1 and
-- 20260919_import_batch_adapter_lineage_v1). Guards the invariant behind the Security Advisor WARN:
-- no SECURITY DEFINER function in an EXPOSED schema (public, graphql_public) may be executable by anon/authenticated,
-- and every SECURITY DEFINER function must pin search_path. PostgREST exposes only public and graphql_public
-- (verified live: `Invalid schema: private`).
do $$
declare f record;
begin
 for f in
  select n.nspname sch, p.proname, p.oid
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where p.prosecdef and n.nspname not in ('pg_catalog','information_schema','pgbouncer','extensions','auth','storage','vault','realtime','graphql','supabase_migrations','net','cron','pgsodium')
 loop
  if not exists(select 1 from pg_proc x where x.oid=f.oid and x.proconfig is not null and exists(select 1 from unnest(x.proconfig) c where c like 'search_path=%')) then
   raise exception 'definer_without_search_path_%.%',f.sch,f.proname;
  end if;
  if has_function_privilege('anon',f.oid,'EXECUTE') then raise exception 'definer_executable_by_anon_%.%',f.sch,f.proname; end if;
  if f.sch in ('public','graphql_public') and has_function_privilege('authenticated',f.oid,'EXECUTE') then
   raise exception 'exposed_definer_executable_by_authenticated_%.%',f.sch,f.proname;
  end if;
 end loop;
 if has_schema_privilege('anon','private','USAGE') then raise exception 'anon_usage_on_private'; end if;
end $$;
