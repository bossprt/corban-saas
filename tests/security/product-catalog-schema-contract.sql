-- Bank/Product/Table V0 post-DDL contract
select to_regclass('public.banks') is not null has_banks,
       to_regclass('public.organization_product_routes') is not null has_routes,
       to_regclass('public.product_tables') is not null has_tables,
       to_regclass('public.product_table_versions') is not null has_versions;

select c.relname table_name,c.relrowsecurity rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('organization_product_routes','product_tables','product_table_versions')
order by c.relname;

select table_name,privilege_type
from information_schema.role_table_grants
where table_schema='public' and grantee='authenticated'
  and table_name in ('banks','providers','agreements','products','modalities','organization_product_routes','product_tables','product_table_versions')
order by table_name,privilege_type;

select conname,pg_get_constraintdef(oid) definition
from pg_constraint
where connamespace='public'::regnamespace
and conname in ('organization_product_routes_modality_product_fk','product_tables_route_tenant_fk','product_table_versions_table_tenant_fk')
order by conname;

select policyname,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename in ('organization_product_routes','product_tables','product_table_versions')
order by tablename,policyname;


-- Service role maintenance is explicit, not inherited accidentally.
select table_name, array_agg(privilege_type order by privilege_type) privileges
from information_schema.role_table_grants
where table_schema='public' and grantee='service_role'
  and table_name in ('banks','providers','agreements','products','modalities','organization_product_routes','product_tables','product_table_versions')
group by table_name order by table_name;
