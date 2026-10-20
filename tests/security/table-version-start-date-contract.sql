-- Contract test for 20260929052528_table_version_start_date_v1: publishing a draft with a chosen start date keeps
-- every publication rule (role, draft only, chronological order, previous vigência closed at the new start).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/table-version-start-date-contract.sql

begin;

-- Dates are relative to today in Brasília (the seed's own published versions start when the seed ran, so fixed past
-- dates could fall before them): v3 starts in 7 days, the draft is published to start in 14.
create temp table dates as
select (now() at time zone 'America/Sao_Paulo')::date + 7 as d_v3,
       (now() at time zone 'America/Sao_Paulo')::date + 3 as d_before,
       (now() at time zone 'America/Sao_Paulo')::date + 14 as d_new,
       (now() at time zone 'America/Sao_Paulo')::date + 15 as d_again;
grant select on dates to authenticated;

-- Own data on the seed table: a published vigência starting in 7 days and a draft after it (rate set, so it can publish).
create temp table made as
with p as (
  insert into public.product_table_versions (organization_id, product_table_id, version, status, effective_from, published_at, rate)
  select organization_id, id, 90, 'published', (select d_v3 from dates)::timestamp at time zone 'America/Sao_Paulo', now(), 1.8 from public.product_tables where id = '00000000-0000-4000-8000-0000000c0201'
  returning id
), d as (
  insert into public.product_table_versions (organization_id, product_table_id, version, status, rate)
  select organization_id, id, 91, 'draft', 1.8 from public.product_tables where id = '00000000-0000-4000-8000-0000000c0201'
  returning id
)
select (select id from p) as v3, (select id from d) as draft;

create temp table ids as
select '00000000-0000-4000-8000-0000000c0201'::uuid as tbl,
       (select draft from made) as draft,
       (select v3 from made) as v3,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.pub(p_date text) returns text language sql as $$
  select pg_temp.err(format('select public.publish_product_table_version(%L::uuid, %L::date)', (select draft from ids), p_date))
$$;
grant execute on function pg_temp.pub(text) to authenticated;

insert into results select 'seed: draft and v3 exist', (select draft is not null and v3 is not null from ids);

select pg_temp.act_as((select seller from ids));
set local role authenticated;
-- A seller cannot even lock the draft for writing (RLS), so the call stops before the role check.
insert into results select 'seller cannot publish', pg_temp.pub((select d_new from dates)::text) ~ '(not_authorized|version_not_found)';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'date required', pg_temp.err(format('select public.publish_product_table_version(%L::uuid, null::date)', (select draft from ids))) like '%effective_from_required%';
insert into results select 'more than a year ahead refused', pg_temp.pub(((now() at time zone 'America/Sao_Paulo')::date + 400)::text) like '%effective_from_out_of_range%';
insert into results select 'before 2000 refused', pg_temp.pub('1999-12-31') like '%effective_from_out_of_range%';
insert into results select 'before the published v3 refused', pg_temp.pub((select d_before from dates)::text) like '%future_published_version_exists%';
reset role;
insert into results select 'refusals left the draft untouched',
  (select status = 'draft' and effective_from is null from public.product_table_versions where id = (select draft from ids));

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'admin publishes with a start date', pg_temp.pub((select d_new from dates)::text) = 'ok';
reset role;
insert into results select 'starts at midnight in Brasília',
  (select status = 'published' and effective_from = (select d_new from dates)::timestamp at time zone 'America/Sao_Paulo' and published_at is not null
   from public.product_table_versions where id = (select draft from ids));
insert into results select 'previous vigência ends at the new start',
  (select effective_until = (select d_new from dates)::timestamp at time zone 'America/Sao_Paulo' from public.product_table_versions where id = (select v3 from ids));

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'published version cannot be published again', pg_temp.pub((select d_again from dates)::text) like '%version_not_draft%';
reset role;

insert into results select 'anon cannot run it', not has_function_privilege('anon', 'public.publish_product_table_version(uuid,date)', 'execute');
insert into results select 'authenticated can run it', has_function_privilege('authenticated', 'public.publish_product_table_version(uuid,date)', 'execute');
insert into results select 'one-argument form still exists', to_regprocedure('public.publish_product_table_version(uuid)') is not null;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 14 then raise exception 'table version start date contract failed'; end if;
end $$;

rollback;
