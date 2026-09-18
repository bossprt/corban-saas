-- Simulation/Proposal V0 post-DDL contract
select to_regclass('public.simulations') is not null has_simulations,
       to_regclass('public.proposals_v2') is not null has_proposals;

select c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('simulations','proposals_v2') order by c.relname;

select conname,pg_get_constraintdef(oid) definition from pg_constraint
where connamespace='public'::regnamespace
and conname in ('simulations_customer_tenant_fk','simulations_table_version_tenant_fk','proposals_v2_customer_tenant_fk','proposals_v2_simulation_tenant_fk','proposals_v2_table_version_tenant_fk')
order by conname;

select table_name,bool_or(privilege_type='DELETE') authenticated_has_delete
from information_schema.role_table_grants
where table_schema='public' and grantee='authenticated' and table_name in ('simulations','proposals_v2')
group by table_name order by table_name;
