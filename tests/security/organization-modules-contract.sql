-- Contract test for 20260924220000_organization_modules_v1 (same local test company and users as the other contracts).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/organization-modules-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;

insert into results select 'every company has every module', (select count(*) from public.organization_modules) = (select count(*) from public.organizations) * array_length(private.module_catalog(), 1);
insert into results select 'every module starts on', bool_and(enabled) from public.organization_modules;

select set_config('request.jwt.claims', json_build_object('sub', (select v1 from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'seller has clientes.create while the module is on', public.has_permission((select org from ids), 'clientes.create');
insert into results select 'seller sees the company modules', 'clientes' = any (public.my_modules((select org from ids)));
do $$ begin
  begin
    update public.organization_modules set enabled = false where organization_id = (select org from ids);
    insert into results values ('members cannot switch modules', not exists (select 1 from public.organization_modules where not enabled));
  exception when others then
    insert into results values ('members cannot switch modules', true);
  end;
end $$;
reset role;

-- The platform turns the module off (service role path, here as the owner).
update public.organization_modules set enabled = false where organization_id = (select org from ids) and module_key = 'clientes';

select set_config('request.jwt.claims', json_build_object('sub', (select v1 from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'permission stops counting when its module is off', not public.has_permission((select org from ids), 'clientes.create');
insert into results select 'module list no longer offers it', not ('clientes' = any (public.my_modules((select org from ids))));
reset role;

select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'not even the administrator keeps a switched-off module', not public.has_permission((select org from ids), 'clientes.view');
insert into results select 'other modules stay on for the administrator', public.has_permission((select org from ids), 'leads.view');
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'organization modules contract failed'; end if;
end $$;

rollback;
