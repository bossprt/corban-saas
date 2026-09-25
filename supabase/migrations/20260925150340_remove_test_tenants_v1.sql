-- Remove the two test companies created for the RLS checks of 18/09/2026, and the login used only for them (owner decision 25/09/2026).
-- Backup of every removed row: supabase/backups/20260925_test_tenants.sql.
--
-- Fail-closed: the removal stops, and nothing is deleted, if either company holds a row in any table other than the default
-- configuration created with it (branches, roles, modules, pipeline stages), its memberships and the platform audit events
-- about it; or if the test login belongs to any other company. The real company (Smart Promotora) is never touched.

do $$
declare
  v_orgs uuid[] := array['9116a949-18f1-4cb0-aeb8-2c89e7ea882a', '9cd3c149-9622-4442-9e26-45230987c3b9']::uuid[];
  v_login uuid := 'd60aa9a9-6f73-4261-b843-7a15227d3300';
  v_allowed text[] := array['public.organization_branches', 'public.organization_roles', 'public.organization_modules',
    'public.operational_stages', 'public.organization_memberships', 'public.platform_admin_audit_events'];
  r record;
  n bigint;
begin
  for r in
    select c.table_schema || '.' || c.table_name as tbl, c.table_schema as s, c.table_name as t
    from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.column_name = 'organization_id' and c.table_schema not in ('pg_catalog', 'information_schema')
  loop
    if r.tbl = any (v_allowed) then continue; end if;
    execute format('select count(*) from %I.%I where organization_id = any ($1)', r.s, r.t) into n using v_orgs;
    if n > 0 then raise exception 'test_tenant_has_data: % (% rows)', r.tbl, n; end if;
  end loop;

  if exists (select 1 from public.organization_memberships where user_id = v_login and not (organization_id = any (v_orgs))) then
    raise exception 'test_login_belongs_to_another_company';
  end if;

  delete from public.platform_admin_audit_events where organization_id = any (v_orgs);
  delete from public.organization_memberships where organization_id = any (v_orgs);
  delete from public.operational_stages where organization_id = any (v_orgs);
  delete from public.organization_modules where organization_id = any (v_orgs);
  delete from public.organization_branches where organization_id = any (v_orgs);

  -- Roles are never deleted through the app (organization_roles_00_guard). The guard is lifted for these two companies only,
  -- inside this transaction, and restored right after.
  alter table public.organization_roles disable trigger organization_roles_00_guard;
  delete from public.organization_roles where organization_id = any (v_orgs);
  alter table public.organization_roles enable trigger organization_roles_00_guard;

  delete from public.organizations where id = any (v_orgs);
  delete from auth.users where id = v_login;
end
$$;
