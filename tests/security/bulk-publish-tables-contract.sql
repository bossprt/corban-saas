-- Contract test for 20261028011018_bulk_publish_tables_v1: many drafts published with one start date, all or nothing,
-- through the same checks as publishing one; the import reports the drafts it touched.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/bulk-publish-tables-contract.sql

begin;

-- A second table on the seed route, and one fresh draft (rate set, so it can publish) on each table.
select set_config('corban.catalog_rpc', 'on', true);
create temp table made as
with t2 as (
  insert into public.product_tables (organization_id, route_id, code, name, status)
  select organization_id, route_id, 't-bulkpublish1', 'TABELA LOTE TESTE', 'active' from public.product_tables where id = '00000000-0000-4000-8000-0000000c0201'
  returning id, organization_id
), d1 as (
  insert into public.product_table_versions (organization_id, product_table_id, version, status, rate)
  select organization_id, id, 95, 'draft', 1.8 from public.product_tables where id = '00000000-0000-4000-8000-0000000c0201'
  returning id
), d2 as (
  insert into public.product_table_versions (organization_id, product_table_id, version, status, rate)
  select organization_id, id, 1, 'draft', 1.8 from t2
  returning id
)
select (select id from d1) as d1, (select id from d2) as d2;
select set_config('corban.catalog_rpc', 'off', true);

create temp table ids as
select (select d1 from made) as d1, (select d2 from made) as d2,
       ((now() at time zone 'America/Sao_Paulo')::date + 20) as start_on,
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
create function pg_temp.bulk(p_ids uuid[], p_date date) returns text language sql as $$
  select pg_temp.err(format('select public.publish_product_table_versions(%L::uuid[], %L::date)', p_ids, p_date))
$$;
grant execute on function pg_temp.bulk(uuid[], date) to authenticated;
create function pg_temp.drafts() returns integer language sql as $$
  select count(*)::int from public.product_table_versions where id in ((select d1 from ids), (select d2 from ids)) and status = 'draft'
$$;

select pg_temp.act_as((select seller from ids));
set local role authenticated;
insert into results select 'seller cannot publish', pg_temp.bulk(array[(select d1 from ids), (select d2 from ids)], (select start_on from ids)) ~ '(not_authorized|version_not_found)';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'empty list refused', pg_temp.bulk(array[]::uuid[], (select start_on from ids)) like '%versions_required%';
insert into results select 'date required', pg_temp.bulk(array[(select d1 from ids)], null) like '%effective_from_required%';
insert into results select 'more than 500 refused', pg_temp.bulk(array(select gen_random_uuid() from generate_series(1, 501)), (select start_on from ids)) like '%too_many_versions%';
-- One bad id makes the whole call fail: the good draft before it is not left published.
insert into results select 'one unknown version fails the whole list', pg_temp.bulk(array[(select d1 from ids), gen_random_uuid()], (select start_on from ids)) like '%version_not_found%';
reset role;
insert into results select 'refusals left both drafts untouched', pg_temp.drafts() = 2;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'admin publishes both at once (repeated id counted once)',
  pg_temp.bulk(array[(select d1 from ids), (select d2 from ids), (select d1 from ids)], (select start_on from ids)) = 'ok';
reset role;
insert into results select 'both published from the chosen day in Brasília',
  (select count(*) = 2 from public.product_table_versions
   where id in ((select d1 from ids), (select d2 from ids)) and status = 'published' and published_at is not null
     and effective_from = (select start_on from ids)::timestamp at time zone 'America/Sao_Paulo');

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'published versions cannot be published again', pg_temp.bulk(array[(select d2 from ids)], (select start_on from ids) + 1) like '%version_not_draft%';
reset role;

insert into results select 'anon cannot run it', not has_function_privilege('anon', 'public.publish_product_table_versions(uuid[],date)', 'execute');
insert into results select 'authenticated can run it', has_function_privilege('authenticated', 'public.publish_product_table_versions(uuid[],date)', 'execute');
insert into results select 'import reports the drafts it touched', pg_get_functiondef('public.import_smart_commercial_rows(uuid,text,uuid,uuid,jsonb)'::regprocedure) like '%''version_ids'',to_jsonb(v_version_ids)%';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) or (select count(*) from results) < 12 then raise exception 'bulk publish tables contract failed'; end if;
end $$;

rollback;
