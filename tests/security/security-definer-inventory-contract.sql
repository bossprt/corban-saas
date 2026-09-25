-- Read-only inventory contract for SECURITY DEFINER functions.
--
-- Since F1 the write path is governed SECURITY DEFINER RPCs in public (ADR-0027 and later), so an exposed definer
-- executable by authenticated is expected. What must always hold:
--   * every SECURITY DEFINER function pins search_path;
--   * anon executes no SECURITY DEFINER function and has no USAGE on the private schema;
--   * every definer in an exposed schema (public, graphql_public) that authenticated may execute checks the caller
--     (auth.uid(), a permission or membership helper) inside its body.
-- Platform schemas (Supabase internals) are out of scope.
do $$
declare f record;
begin
 for f in
  select n.nspname sch, p.proname, p.oid, p.prosrc
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where p.prosecdef and n.nspname not in ('pg_catalog','information_schema','pgbouncer','extensions','auth','storage','vault','realtime','graphql','supabase_migrations','net','cron','pgsodium','supabase_functions')
 loop
  if not exists(select 1 from pg_proc x where x.oid=f.oid and x.proconfig is not null and exists(select 1 from unnest(x.proconfig) c where c like 'search_path=%')) then
   raise exception 'definer_without_search_path_%.%',f.sch,f.proname;
  end if;
  if has_function_privilege('anon',f.oid,'EXECUTE') then raise exception 'definer_executable_by_anon_%.%',f.sch,f.proname; end if;
  if f.sch in ('public','graphql_public') and has_function_privilege('authenticated',f.oid,'EXECUTE')
     and f.prosrc !~* '(auth\.uid\(\)|has_permission|is_active_organization_member|caller_role_in|has_active_organization_role|is_payout_holder|can_see_|editable_client)' then
   raise exception 'exposed_definer_without_caller_check_%.%',f.sch,f.proname;
  end if;
 end loop;
 if has_schema_privilege('anon','private','USAGE') then raise exception 'anon_usage_on_private'; end if;
end $$;
