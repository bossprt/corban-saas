-- Platform admin boundary: tenant authenticated users have no direct table privileges.
select grantee,privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='platform_administrators'
order by grantee,privilege_type;

select c.relrowsecurity rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='platform_administrators';

-- Admin organization bootstrap post-DDL contract
select p.proname, p.prosecdef,
       has_function_privilege('anon', p.oid, 'EXECUTE') anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') authenticated_execute,
       has_function_privilege('service_role', p.oid, 'EXECUTE') service_role_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='bootstrap_organization_admin';

-- Expected: prosecdef=true, anon=false, authenticated=false, service_role=true.


select grantee,privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='platform_admin_audit_events'
order by grantee,privilege_type;
