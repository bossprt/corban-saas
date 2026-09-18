-- Digitization/Pipeline V0 post-DDL contract
select to_regclass('public.digitization_jobs') is not null has_jobs,
       to_regclass('public.operational_cases') is not null has_cases,
       to_regclass('public.operational_events') is not null has_events;

select c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('operational_stages','digitization_jobs','operational_cases','operational_events') order by c.relname;

select table_name,bool_or(privilege_type='DELETE') authenticated_has_delete,
       bool_or(privilege_type='UPDATE') authenticated_has_update
from information_schema.role_table_grants
where table_schema='public' and grantee='authenticated'
and table_name in ('operational_stages','digitization_jobs','operational_cases','operational_events')
group by table_name order by table_name;

select conname,pg_get_constraintdef(oid) definition from pg_constraint
where connamespace='public'::regnamespace and conname in (
'digitization_jobs_proposal_tenant_fk','operational_cases_proposal_tenant_fk',
'operational_cases_digitization_tenant_fk','operational_cases_stage_tenant_fk',
'operational_cases_stage_state_fk','operational_events_case_tenant_fk') order by conname;

select indexname,indexdef from pg_indexes
where schemaname='public' and indexname='digitization_jobs_active_proposal_key';


select table_name,array_agg(privilege_type order by privilege_type) privileges
from information_schema.role_table_grants
where table_schema='public' and grantee='service_role'
and table_name in ('operational_stages','digitization_jobs','operational_cases','operational_events')
group by table_name order by table_name;


select tgname,pg_get_triggerdef(oid) definition
from pg_trigger
where tgrelid='public.digitization_jobs'::regclass
  and tgname='digitization_jobs_documents_ready_guard'
  and not tgisinternal;
