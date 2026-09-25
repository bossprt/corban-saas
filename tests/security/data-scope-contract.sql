-- Contract test for 20260924114941_data_scope_visibility_v1. Runs on a local or test database seeded with
-- supabase/seed/f0-test-tenant.sql and four users of the test company:
--   admin@corban-teste.local (Administrador), supervisor@corban-teste.local (Supervisor, scope team),
--   vendedor@corban-teste.local and vendedor2@corban-teste.local (Vendedor, scope own).
-- One transaction, rolled back. Any failed expectation stops the script.
--   psql -v ON_ERROR_STOP=1 -f tests/security/data-scope-contract.sql

begin;

create temp table ids as
select
  '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
  (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
  (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
  (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
  (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- Hierarchy: the supervisor leads vendedor (not vendedor2). Done by the administrator through the governed RPC.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
reset role;

-- Each seller creates a client with an address and a lead.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
with c as (insert into public.clients (organization_id, full_name, cpf) values ((select org from ids), 'Cliente do Vendedor Um', '52998224725') returning id)
insert into made select 'c1', id from c;
insert into public.customer_addresses (organization_id, customer_id, street, city, state, postal_code)
select (select org from ids), id, 'Rua Um', 'Rio Branco', 'AC', '69900000' from made where label = 'c1';
select public.create_lead((select org from ids), 'manual', 'Lead do Vendedor Um', '+5568999000101', null, null, null, '{}'::jsonb);
reset role;

select pg_temp.act_as((select v2 from ids));
set local role authenticated;
with c as (insert into public.clients (organization_id, full_name, cpf) values ((select org from ids), 'Cliente do Vendedor Dois', '11144477735') returning id)
insert into made select 'c2', id from c;
reset role;

-- Vendedor Um: sees only what is his.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'v1 sees his client', exists (select 1 from public.clients where id = (select id from made where label = 'c1'));
insert into results select 'v1 does not see v2 client', not exists (select 1 from public.clients where id = (select id from made where label = 'c2'));
insert into results select 'v1 does not see unowned seed clients', not exists (select 1 from public.clients where owner_user_id is null);
insert into results select 'v1 sees his client address', exists (select 1 from public.customer_addresses where customer_id = (select id from made where label = 'c1'));
insert into results select 'v1 sees his lead', exists (select 1 from public.leads where full_name = 'Lead do Vendedor Um');
do $$
declare n int;
begin
  update public.clients set notes = 'invadido' where id = (select id from made where label = 'c2');
  get diagnostics n = row_count;
  insert into results values ('v1 cannot update v2 client', n = 0);
  begin
    update public.clients set owner_user_id = (select v2 from ids) where id = (select id from made where label = 'c1');
    insert into results values ('owner cannot be changed outside the governed path', false);
  exception when others then
    insert into results values ('owner cannot be changed outside the governed path', sqlerrm = 'client_owner_change_requires_governed_rpc');
  end;
  begin
    perform public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v2 from ids)), null, null, 'all');
    insert into results values ('seller cannot change hierarchy', false);
  exception when others then
    insert into results values ('seller cannot change hierarchy', true);
  end;
end $$;
reset role;

-- Vendedor Dois: does not see Vendedor Um's address or lead.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'v2 does not see v1 address', not exists (select 1 from public.customer_addresses where customer_id = (select id from made where label = 'c1'));
insert into results select 'v2 does not see v1 lead', not exists (select 1 from public.leads where full_name = 'Lead do Vendedor Um');
reset role;

-- Supervisor (scope team): sees the team member's client, not the other seller's.
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'supervisor sees team client', exists (select 1 from public.clients where id = (select id from made where label = 'c1'));
insert into results select 'supervisor does not see non-team client', not exists (select 1 from public.clients where id = (select id from made where label = 'c2'));
insert into results select 'supervisor sees team lead', exists (select 1 from public.leads where full_name = 'Lead do Vendedor Um');
reset role;

-- Administrator: sees everything, and can open the whole company to a person.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'admin sees all clients', (select count(*) from public.clients where organization_id = (select org from ids)) >= 7;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v2 from ids)), null, null, 'all');
insert into results select 'hierarchy change is audited', exists (select 1 from public.organization_admin_events where event_type = 'member_hierarchy_changed');
reset role;

select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'scope exception opens the company to v2', exists (select 1 from public.clients where id = (select id from made where label = 'c1'));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'data scope contract failed'; end if;
end $$;

rollback;
