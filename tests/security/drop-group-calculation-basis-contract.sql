-- Contract test for 20260929060655_drop_group_calculation_basis_v1: the misleading column is gone, its backup is
-- private, and creating a seller group still works. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/drop-group-calculation-basis-contract.sql

begin;

create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;

insert into results select 'column removed',
  not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'commission_groups' and column_name = 'calculation_basis');
insert into results select 'guard trigger removed',
  not exists (select 1 from pg_trigger where tgrelid = 'public.commission_groups'::regclass and tgname = 'commission_groups_20_received_basis_guard');
-- The backup keeps id, company, name and the old value of each group that existed when the migration ran (none in a
-- local rebuild, where the seed comes after the migrations).
insert into results select 'backup table has the old column',
  (select count(*) from information_schema.columns where table_schema = 'backup_c6' and table_name = 'commission_groups_calculation_basis'
   and column_name in ('id', 'organization_id', 'name', 'calculation_basis')) = 4;
insert into results select 'backup not readable by the app',
  not has_schema_privilege('authenticated', 'backup_c6', 'usage') and not has_schema_privilege('anon', 'backup_c6', 'usage');
insert into results select 'no function mentions the column',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public', 'private') and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%calculation_basis%');

-- An admin still creates a seller group through the governed function.
select set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where email = 'admin@corban-teste.local'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'admin creates a group',
  public.save_seller_group('00000000-0000-4000-8000-00000000c0b1', null, 'Grupo sem base', true, '[]'::jsonb, 'spread', '0', 'spread', '0') is not null;
reset role;
insert into results select 'group saved', exists (select 1 from public.commission_groups where name = 'Grupo sem base');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 7 then raise exception 'drop group calculation basis contract failed'; end if;
end $$;

rollback;
