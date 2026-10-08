-- Contract test for 20261008141157_factor_price_import_v1: the bank's Fator Price is imported by the bank's table code and
-- serves every partner promoter that sells that table; one published daily batch per date; a date without factor
-- (weekend, holiday) offers nothing; importing again changes nothing; a changed factor is a new revision; a code
-- without table is reported; a seller and another company are refused. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/factor-price-import-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user,
       (select id from public.contract_types where tech_key = 'novo' and organization_id is null) as novo,
       date '2026-12-01' as d1, date '2026-12-02' as d2, date '2026-12-05' as saturday;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table seen (label text, b jsonb);
grant insert, select on seen to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as((select admin_user from ids));
-- One bank, one agreement, two partner promoters selling the same bank table 745031.
insert into public.organization_banks (organization_id, name, is_active) select org, 'Daycoval Contrato', true from ids returning id \gset bank_
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Gov Contrato', true from ids returning id \gset agr_
insert into public.organization_providers (organization_id, name) select org, 'Promotora A Contrato' from ids returning id \gset pa_
insert into public.organization_providers (organization_id, name) select org, 'Promotora B Contrato' from ids returning id \gset pb_
insert into made values ('bank', :'bank_id'), ('agreement', :'agr_id'), ('pa', :'pa_id'), ('pb', :'pb_id');

create function pg_temp.table_for(p_provider uuid, p_code text, p_name text) returns uuid language plpgsql as $$
declare r uuid; t uuid; v uuid;
begin
  insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, org_provider_id, production_origin, status)
  values ((select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'), p_provider, 'third_party', 'active')
  returning id into r;
  insert into public.product_tables (organization_id, route_id, code, name, status, formalization, bank_table_code)
  values ((select org from ids), r, p_code, p_name, 'active', 'digital', '745031') returning id into t;
  insert into public.product_table_versions (organization_id, product_table_id, version, status) values ((select org from ids), t, 1, 'draft') returning id into v;
  insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, tax_pct)
  values ((select org from ids), v, (select novo from ids), 120, 120, 120, 0);
  perform public.publish_product_table_version(v, current_date - 1);
  return t;
end $$;
select pg_temp.table_for((select id from made where label = 'pa'), 'ctr-a-745031', 'DAYCOVAL TAB 1 (A)');
select pg_temp.table_for((select id from made where label = 'pb'), 'ctr-b-745031', '745031 - TAB 1 (B)');

create temp table sheets as select jsonb_build_array(
  jsonb_build_object('code', '745031', 'label', 'RFNGOVTAB1', 'dates', jsonb_build_array(
    jsonb_build_object('date', (select d1 from ids), 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '0.02816'))),
    jsonb_build_object('date', (select d2 from ids), 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '0.02813'))))),
  jsonb_build_object('code', '999999', 'label', 'SEMTABELA', 'dates', jsonb_build_array(
    jsonb_build_object('date', (select d1 from ids), 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '0.03'))))))
  as s;
grant select on sheets to authenticated;

select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller cannot import factors',
  pg_temp.err(format('select public.import_factor_price(%L, %L, %L, %L::jsonb)', (select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select s from sheets))) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'another company is refused',
  pg_temp.err(format('select public.import_factor_price(%L, %L, %L, %L::jsonb)', gen_random_uuid(), (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select s from sheets))) like '%not_authorized%';
insert into results select 'a factor of 1 or more is refused',
  pg_temp.err(format('select public.import_factor_price(%L, %L, %L, %L::jsonb)', (select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'),
    jsonb_build_array(jsonb_build_object('code', '745031', 'dates', jsonb_build_array(jsonb_build_object('date', (select d1 from ids), 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '1.2')))))))) like '%factor_price_invalid_factor%';
insert into seen select 'first', public.import_factor_price((select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select s from sheets), 'contrato');
insert into seen select 'again', public.import_factor_price((select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select s from sheets), 'contrato');
insert into seen select 'd1', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 120, 'amount', 10000, null, (select d1 from ids));
insert into seen select 'd2', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 120, 'amount', 10000, null, (select d2 from ids));
insert into seen select 'saturday', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 120, 'amount', 10000, null, (select saturday from ids));
insert into seen select 'changed', public.import_factor_price((select org from ids), (select id from made where label = 'bank'), (select id from made where label = 'agreement'),
  jsonb_build_array(jsonb_build_object('code', '745031', 'dates', jsonb_build_array(jsonb_build_object('date', (select d1 from ids), 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '0.02900')))))), 'contrato');
insert into seen select 'd1_after', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 120, 'amount', 10000, null, (select d1 from ids));
reset role;

insert into results select 'first import: one profile, two dates published, the code without table is reported',
  (select b = '{"profiles_created":1,"batches_published":2,"batches_unchanged":0,"codes_without_table":["999999"]}'::jsonb from seen where label = 'first');
insert into results select 'the same file again changes nothing',
  (select (b->>'profiles_created')::int = 0 and (b->>'batches_published')::int = 0 and (b->>'batches_unchanged')::int = 2 from seen where label = 'again');
insert into results select 'both promoters get the bank factor of the date (installment 281,60 on day 1)',
  (select count(*) = 2 and bool_and((e->>'installment')::numeric = 281.60 and e->>'factor_source' = 'daily') from seen, jsonb_array_elements(b) e where label = 'd1');
insert into results select 'day 2 uses its own factor (281,30)',
  (select bool_and((e->>'installment')::numeric = 281.30) and count(*) = 2 from seen, jsonb_array_elements(b) e where label = 'd2');
insert into results select 'a day without factor (weekend) offers nothing', (select b = '[]'::jsonb from seen where label = 'saturday');
insert into results select 'a changed factor is a new revision and is used (290,00); history kept',
  (select (b->>'batches_published')::int = 1 from seen where label = 'changed')
  and (select bool_and((e->>'installment')::numeric = 290.00) from seen, jsonb_array_elements(b) e where label = 'd1_after')
  and (select count(*) = 3 from public.commercial_factor_batches b join public.commercial_factor_profiles p on p.id = b.profile_id
       where p.bank_table_code = '745031' and p.org_bank_id = (select id from made where label = 'bank') and b.status = 'published');
insert into results select 'a profile cannot point at one table and a bank code at once',
  pg_temp.err(format('update public.commercial_factor_profiles set product_table_id = (select id from public.product_tables where code = %L) where bank_table_code = %L', 'ctr-a-745031', '745031')) like '%one_table_scope%';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'factor price import contract failed'; end if;
end $$;
rollback;
