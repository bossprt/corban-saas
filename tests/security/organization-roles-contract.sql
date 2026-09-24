-- Contract test for 20260924071259_organization_roles_permissions_v1. Runs on a local or test database seeded with
-- supabase/seed/f0-test-tenant.sql plus two users: admin@corban-teste.local (admin) and vendedor@corban-teste.local (agent).
-- Everything happens inside one transaction that is rolled back. Any failed expectation raises and stops the script.
--   psql -v ON_ERROR_STOP=1 -f tests/security/organization-roles-contract.sql

begin;

create temp table ids as
select
  '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
  (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
  (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
grant select on ids to authenticated;

create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;

-- System roles and backfill (as the migration owner).
insert into results
select 'seven system roles', count(*) = 7 from public.organization_roles where organization_id = (select org from ids) and is_system;
insert into results
select 'every membership has a role whose tier matches', bool_and(m.role = r.tier)
from public.organization_memberships m join public.organization_roles r on r.id = m.role_id
where m.organization_id = (select org from ids);

-- As the seller (agent tier, role vendedor).
select set_config('request.jwt.claims', json_build_object('sub', (select seller_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;

insert into results select 'seller sees the company roles', count(*) = 7 from public.organization_roles where organization_id = (select org from ids);
insert into results select 'seller may create clients', public.has_permission((select org from ids), 'clientes.create');
insert into results select 'seller may not approve payouts', not public.has_permission((select org from ids), 'repasse.approve');
insert into results select 'seller access is own scope', (select scope = 'own' and role_key = 'vendedor' from public.my_access((select org from ids)));

do $$
begin
  begin
    insert into public.organization_roles (organization_id, key, name, tier, scope) values ((select org from ids), 'hack', 'Hack', 'manager', 'all');
    insert into results values ('seller direct role insert is refused', false);
  exception when others then
    insert into results values ('seller direct role insert is refused', true);
  end;
  begin
    perform public.save_organization_role((select org from ids), null, 'hack', 'Hack', 'manager', 'all', array['repasse.approve']);
    insert into results values ('seller cannot save roles', false);
  exception when others then
    insert into results values ('seller cannot save roles', sqlerrm = 'not_authorized');
  end;
  begin
    update public.organization_memberships set role = 'admin' where user_id = (select seller_user from ids);
    insert into results values ('seller cannot raise own tier', not exists (select 1 from public.organization_memberships where user_id = (select seller_user from ids) and role = 'admin'));
  exception when others then
    insert into results values ('seller cannot raise own tier', true);
  end;
end $$;

reset role;

-- As the administrator.
select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare v_role uuid; v_membership uuid;
begin
  begin
    perform public.save_organization_role((select org from ids), null, 'digitador', 'Digitador', 'agent', 'all', array['propostas.view','esteira.edit','nao.existe']);
    insert into results values ('unknown permission is refused', false);
  exception when others then
    insert into results values ('unknown permission is refused', sqlerrm = 'unknown_permission');
  end;
  begin
    perform public.save_organization_role((select org from ids), null, 'dono2', 'Outro dono', 'admin', 'all', '{}');
    insert into results values ('custom role cannot be admin tier', false);
  exception when others then
    insert into results values ('custom role cannot be admin tier', sqlerrm = 'invalid_role_tier');
  end;

  v_role := public.save_organization_role((select org from ids), null, 'digitador', 'Digitador', 'agent', 'all', array['propostas.view','esteira.view','esteira.edit']);
  insert into results values ('admin creates a custom role', v_role is not null);

  select id into v_membership from public.organization_memberships where user_id = (select seller_user from ids);
  perform public.assign_member_access_role(v_membership, v_role);
  insert into results select 'member moves to the custom role', role_id = v_role and role = 'agent' from public.organization_memberships where id = v_membership;

  perform public.save_organization_role((select org from ids), v_role, null, 'Digitador', 'supervisor', 'all', array['propostas.view','esteira.view','esteira.edit']);
  insert into results select 'members follow a changed custom tier and keep the role', role = 'supervisor' and role_id = v_role from public.organization_memberships where id = v_membership;

  begin
    perform public.save_organization_role((select org from ids), v_role, null, 'Digitador', 'supervisor', 'all', '{}', false);
    insert into results values ('role in use cannot be deactivated', false);
  exception when others then
    insert into results values ('role in use cannot be deactivated', sqlerrm = 'role_in_use');
  end;

  begin
    perform public.save_organization_role((select org from ids), (select id from public.organization_roles where organization_id = (select org from ids) and key = 'admin'), null, 'Chefe', 'admin', 'all', '{}');
    insert into results values ('system admin role is fixed', false);
  exception when others then
    insert into results values ('system admin role is fixed', sqlerrm = 'admin_role_is_fixed');
  end;

  begin
    perform public.assign_member_access_role((select id from public.organization_memberships where user_id = (select admin_user from ids)), v_role);
    insert into results values ('admin cannot change own access', false);
  exception when others then
    insert into results values ('admin cannot change own access', sqlerrm = 'cannot_change_own_membership');
  end;

  insert into results select 'changes are audited', count(*) >= 3 from public.organization_admin_events
  where organization_id = (select org from ids) and event_type in ('role_created', 'role_updated', 'member_access_role_changed');
end $$;

reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'organization roles contract failed'; end if;
end $$;

rollback;
