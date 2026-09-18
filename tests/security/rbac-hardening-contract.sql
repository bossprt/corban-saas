-- POST-APPLY CONTRACT for 20260918_rbac_hardening_v0.sql
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='has_active_organization_role' and p.prosecdef=true
  ) then raise exception 'role helper missing'; end if;
  if has_function_privilege('anon','public.has_active_organization_role(uuid,text[])','EXECUTE') then
    raise exception 'anon must not execute role helper';
  end if;

  if exists (
    select 1 from pg_policies where schemaname='public'
      and policyname in (
        'organization_product_routes_insert_member','organization_product_routes_update_member',
        'product_tables_insert_member','product_tables_update_member',
        'product_table_versions_insert_member','product_table_versions_update_draft_member',
        'operational_stages_insert_member','operational_stages_update_member',
        'customer_documents_update_member'
      )
  ) then raise exception 'legacy member-wide write policy remains'; end if;

  if not exists (
    select 1 from pg_policies where schemaname='public' and tablename='product_tables'
      and policyname='product_tables_insert_manager'
  ) then raise exception 'catalog manager policy missing'; end if;
end $$;
