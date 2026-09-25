-- Legacy policy migration post-DDL inspection
select tablename,policyname,roles,cmd,qual,with_check
from pg_policies
where schemaname='public'
  and tablename in ('organizations','profiles','clients','contracts','import_jobs')
order by tablename,cmd,policyname;

-- Legacy generic policies should be absent.
select count(*) as legacy_policy_count
from pg_policies
where schemaname='public'
  and policyname in ('Isolamento de Organizacoes','Isolamento de Perfis','Isolamento de Clientes','Isolamento de Contratos','Isolamento de Importacoes');

-- New helper remains executable only for intended roles.
select routine_name,grantee,privilege_type
from information_schema.routine_privileges
where routine_schema='public'
  and routine_name in ('is_active_organization_member','get_user_organization_id')
order by routine_name,grantee;
