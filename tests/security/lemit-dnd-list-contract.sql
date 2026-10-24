-- Contract test for 20261024203819_lemit_dnd_list_v1: the Lemit "Não Perturbe SP" list is imported in chunks by the
-- administrator; importing again replaces the previous Lemit list; phones marked by hand stay; a phone counts only from its
-- validity date. One transaction, rolled back. Fictitious phones only.
--   psql -v ON_ERROR_STOP=1 -f tests/security/lemit-dnd-list-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       gen_random_uuid() as b1, gen_random_uuid() as b2,
       (now() at time zone 'America/Sao_Paulo')::date as today;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.on_list(p_phone text) returns boolean language sql as $$ select private.phone_is_dnd((select org from ids), p_phone) $$;

-- A phone marked by hand that also comes in the Lemit file.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.mark_phone_dnd((select org from ids), '68999000003', 'Cliente pediu', null);

-- First Lemit list: three phones (one valid only in the future, one already marked by hand) plus an invalid one.
insert into results select 'the first chunk is written (the hand-marked phone is left as it is)',
  (public.import_lemit_dnd_chunk((select org from ids), (select b1 from ids), 'nao-perturbe.csv.zip', jsonb_build_array(
     jsonb_build_object('phone', '68999000001', 'valid_from', ((select today from ids) - 10)::text),
     jsonb_build_object('phone', '68999000002', 'valid_from', ((select today from ids) + 30)::text),
     jsonb_build_object('phone', '68999000003', 'valid_from', ((select today from ids) - 5)::text),
     jsonb_build_object('phone', '123', 'valid_from', null)))->>'written')::int = 2;
insert into results select 'finishing reports the list', (public.finish_lemit_dnd_import((select org from ids), (select b1 from ids))->>'total')::int = 2;
reset role;
insert into results select 'a valid Lemit phone is on the list', pg_temp.on_list('(68) 99900-0001');
insert into results select 'a phone with a future validity date is not counted yet', not pg_temp.on_list('68999000002');
insert into results select 'the hand-marked phone keeps its origin',
  (select source = 'manual' from public.do_not_disturb_phones where organization_id = (select org from ids) and phone = '5568999000003' and removed_at is null);

-- Second Lemit list: phone 1 is gone, phone 4 is new. The old Lemit phone leaves; the hand-marked one stays.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.import_lemit_dnd_chunk((select org from ids), (select b2 from ids), 'nao-perturbe-2.csv', jsonb_build_array(
  jsonb_build_object('phone', '68999000002', 'valid_from', ((select today from ids) - 1)::text),
  jsonb_build_object('phone', '68999000004', 'valid_from', null)));
insert into results select 'the new list replaces the old one (one old Lemit phone removed)',
  (public.finish_lemit_dnd_import((select org from ids), (select b2 from ids))->>'removed')::int = 1;
reset role;
insert into results select 'phone 1 left the list', not pg_temp.on_list('68999000001');
insert into results select 'phone 2 now counts (new validity date)', pg_temp.on_list('68999000002');
insert into results select 'phone 4 joined', pg_temp.on_list('68999000004');
insert into results select 'the hand-marked phone is still there', pg_temp.on_list('68999000003');

-- Only the administrator imports.
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'a supervisor cannot import the Lemit list',
  pg_temp.err(format('select public.import_lemit_dnd_chunk(%L, gen_random_uuid(), %L, %L::jsonb)', (select org from ids), 'x.csv', '[]')) like '%not_authorized%';
insert into results select 'a supervisor cannot finish an import',
  pg_temp.err(format('select public.finish_lemit_dnd_import(%L, %L)', (select org from ids), (select b2 from ids))) like '%not_authorized%';
reset role;
insert into results select 'anon cannot call the import', not has_function_privilege('anon', 'public.import_lemit_dnd_chunk(uuid, uuid, text, jsonb)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'lemit dnd list contract failed'; end if;
end $$;
rollback;
