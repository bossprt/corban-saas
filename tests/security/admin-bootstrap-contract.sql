-- Admin organization bootstrap post-DDL contract
select p.proname, p.prosecdef,
       has_function_privilege('anon', p.oid, 'EXECUTE') anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') service_role_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='bootstrap_organization_admin';

-- Expected: prosecdef=true, anon=false, authenticated=false, service_role=true.
