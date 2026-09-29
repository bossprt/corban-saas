-- Contract test for 20260929051253_prosesp_tables_publish_v1: the three PROSESP drafts are published with vigência
-- from 01/01/2026 (Brasília), and the migration refuses unexpected states instead of guessing.
-- One transaction, rolled back. The migration file must be reachable at /tmp/prosesp_publish.sql:
--   docker cp supabase/migrations/20260929051253_prosesp_tables_publish_v1.sql <db>:/tmp/prosesp_publish.sql
--   psql -v ON_ERROR_STOP=1 -f tests/security/prosesp-tables-publish-contract.sql

begin;

create temp table results (check_name text, ok boolean);

-- Nothing to publish in a database without the tables.
\i /tmp/prosesp_publish.sql
insert into results select 'no PROSESP tables: nothing changes',
  not exists (select 1 from public.product_tables where code like 'prosesp-ac-%');

-- Three drafts shaped like production: one table, one draft version, one commission line each.
create temp table src as
select v.organization_id as org, t.route_id as route, c.id as cond
from public.commercial_conditions c
join public.product_table_versions v on v.id = c.product_table_version_id
join public.product_tables t on t.id = v.product_table_id
limit 1;

select set_config('corban.catalog_rpc', 'on', true), set_config('corban.condition_rpc', 'on', true), set_config('corban.smart_import_rpc', 'on', true);
create temp table made as
with t as (
  insert into public.product_tables (organization_id, route_id, code, name)
  select org, route, x.code, 'PROSESP teste ' || x.code from src, unnest(array['prosesp-ac-comissionado', 'prosesp-ac-efetivo', 'prosesp-ac-temporario']) as x(code)
  returning id, organization_id, code
), v as (
  insert into public.product_table_versions (organization_id, product_table_id, version, status)
  select organization_id, id, 1, 'draft' from t returning id, product_table_id, organization_id
)
select v.id as version_id, t.code from v join t on t.id = v.product_table_id;
insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, tax_pct)
select c.organization_id, m.version_id, c.contract_type_id, c.term, c.term_min, c.term_max, c.amount_min, c.amount_max, c.tax_pct
from made m, src s join public.commercial_conditions c on c.id = s.cond;
select set_config('corban.catalog_rpc', 'off', true), set_config('corban.condition_rpc', 'off', true), set_config('corban.smart_import_rpc', 'off', true);

-- A fourth draft of one of them is an unexpected state: refused, nothing published.
\set mig `cat /tmp/prosesp_publish.sql`
create temp table mig as select :'mig'::text as sql;
create function pg_temp.run_migration() returns text language plpgsql as $$
begin
  execute (select sql from mig);
  return 'ok';
exception when others then return sqlerrm; end $$;
savepoint extra;
insert into public.product_table_versions (organization_id, product_table_id, version, status)
select v.organization_id, v.product_table_id, 2, 'draft' from public.product_table_versions v join made m on m.version_id = v.id where m.code = 'prosesp-ac-efetivo';
select pg_temp.run_migration() like '%prosesp_tables_unexpected_draft_count%' as refused,
  not exists (select 1 from public.product_table_versions v join made m on m.version_id = v.id where v.status <> 'draft') as untouched \gset
rollback to savepoint extra;
insert into results values ('four drafts: refused', :'refused'::boolean), ('four drafts: nothing published', :'untouched'::boolean);

\i /tmp/prosesp_publish.sql

insert into results select 'three versions published',
  (select count(*) from public.product_table_versions v join made m on m.version_id = v.id where v.status = 'published' and v.published_at is not null) = 3;
insert into results select 'vigência from 01/01/2026 Brasília',
  (select bool_and(v.effective_from = '2026-01-01 03:00:00+00'::timestamptz and v.effective_until is null) from public.product_table_versions v join made m on m.version_id = v.id);
insert into results select 'second run changes nothing',
  pg_temp.run_migration() = 'ok'
  and (select count(*) from public.product_table_versions v join made m on m.version_id = v.id where v.status = 'published') = 3;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
insert into results select 'start date locked after publishing',
  pg_temp.err(format('update public.product_table_versions set effective_from = now() where id = %L', (select version_id from made limit 1))) like '%published_product_table_version_is_immutable%';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 7 then raise exception 'prosesp tables publish contract failed'; end if;
end $$;

rollback;
