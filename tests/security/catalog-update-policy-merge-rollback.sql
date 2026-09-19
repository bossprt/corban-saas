-- Rollback-only verification for 20260930_catalog_update_policy_merge_v1.
-- Run migration text first in the same transaction until LIVE; then this block only.
do $test$
declare n int;
begin
 select count(*) into n from pg_policies
 where schemaname='public' and tablename='product_table_versions' and cmd='UPDATE' and 'authenticated'=any(roles);
 if n<>1 then raise exception 'product_table_versions expected 1 UPDATE policy, got %',n; end if;

 select count(*) into n from pg_policies
 where schemaname='public' and tablename='document_checklist_templates' and cmd='UPDATE' and 'authenticated'=any(roles);
 if n<>1 then raise exception 'document_checklist_templates expected 1 UPDATE policy, got %',n; end if;

 if not exists(select 1 from pg_policies where schemaname='public' and tablename='product_table_versions' and policyname='product_table_versions_update_manager')
 then raise exception 'merged product policy missing'; end if;

 if not exists(select 1 from pg_policies where schemaname='public' and tablename='document_checklist_templates' and policyname='document_checklist_templates_update_supervisor')
 then raise exception 'merged checklist policy missing'; end if;

 raise exception 'RESULTS: ALL PASS (4 checks)';
end $test$;
