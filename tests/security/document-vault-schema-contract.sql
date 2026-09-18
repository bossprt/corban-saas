-- Document Vault V0 post-DDL security contract
select to_regclass('public.customer_documents') is not null has_customer_documents,
       to_regclass('public.document_checklist_templates') is not null has_templates,
       to_regclass('public.proposal_document_requirements') is not null has_requirements,
       to_regclass('public.proposal_document_links') is not null has_links;

select c.relname,c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('customer_documents','document_checklist_templates','document_checklist_items','proposal_document_requirements','proposal_document_links')
order by c.relname;

select table_name,bool_or(privilege_type='DELETE') authenticated_has_delete
from information_schema.role_table_grants
where table_schema='public' and grantee='authenticated'
and table_name in ('customer_documents','document_checklist_templates','document_checklist_items','proposal_document_requirements','proposal_document_links')
group by table_name order by table_name;

select conname,pg_get_constraintdef(oid) definition from pg_constraint
where connamespace='public'::regnamespace and conname like '%tenant_fk' and conname in (
'customer_documents_customer_tenant_fk','document_checklist_templates_route_tenant_fk',
'document_checklist_items_template_tenant_fk','proposal_document_requirements_proposal_tenant_fk',
'proposal_document_requirements_item_tenant_fk','proposal_document_links_requirement_tenant_fk',
'proposal_document_links_document_tenant_fk') order by conname;


select tgname,pg_get_triggerdef(oid) definition
from pg_trigger
where tgrelid='public.proposal_document_requirements'::regclass
  and tgname='proposal_document_requirements_snapshot_guard'
  and not tgisinternal;

select conname,pg_get_constraintdef(oid) definition
from pg_constraint
where conrelid='public.proposal_document_requirements'::regclass
  and conname in ('proposal_document_requirements_exception_check','proposal_document_requirements_exception_scope_check')
order by conname;

select policyname,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename='document_checklist_items'
order by policyname;
