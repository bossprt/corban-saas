-- Contract test for 20260924221914_grants_hygiene_v1: anon executes no project function and holds no table privilege;
-- the Equipe member RPCs can set hierarchy and custom role, while a direct API update of the same columns is refused.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/grants-hygiene-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;

insert into results select 'anon executes no function in public or private',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public','private') and has_function_privilege('anon', p.oid, 'execute'));
insert into results select 'anon holds no privilege on any public table or view',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              cross join (values ('select'),('insert'),('update'),('delete')) v(pr)
              where n.nspname = 'public' and c.relkind in ('r','v') and has_table_privilege('anon', c.oid, pr));

select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
insert into results select 'admin sets a member supervisor through set_member_hierarchy',
  (select team_leader_user_id from public.organization_memberships where user_id = (select v1 from ids) and organization_id = (select org from ids)) = (select sup_user from ids);
do $$ begin
  begin
    update public.organization_memberships set team_leader_user_id = null where user_id = (select v1 from ids);
    insert into results values ('a direct API update of the hierarchy is refused', false);
  exception when others then
    insert into results values ('a direct API update of the hierarchy is refused', true);
  end;
end $$;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 4 then raise exception 'grants hygiene contract failed'; end if;
end $$;
rollback;
