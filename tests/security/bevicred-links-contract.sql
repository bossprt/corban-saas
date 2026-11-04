-- Contract test for 20261104013646_bevicred_links_v1: the table is closed to tenants; a link points only to a table or
-- seller of the same company; one link per company, kind and Bevicred key. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/bevicred-links-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000bb003'::uuid as org_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a,
       (select id from public.product_tables where organization_id = '00000000-0000-4000-8000-00000000c0b1' limit 1) as table_a,
       (select id from public.commercial_sellers where organization_id = '00000000-0000-4000-8000-00000000c0b1' limit 1) as seller_a;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Bevicred links', 'bevicred-links-' || gen_random_uuid(), 'starter', true from ids;

insert into results select 'fixtures present', table_a is not null and seller_a is not null from ids;
insert into results select 'table link of the company',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''table'', ''inss ml dweb tkt'', ''INSS ML DWEB Tkt'', %L)', org_a, table_a)) = 'ok' from ids;
insert into results select 'seller link of the company',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''seller'', ''SP18-000001'', ''Parceiro'', %L)', org_a, seller_a)) = 'ok' from ids;
insert into results select 'table of another company refused',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''table'', ''x'', ''x'', %L)', org_b, table_a)) like '%bevicred_link_target_not_in_company%' from ids;
insert into results select 'seller of another company refused',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''seller'', ''x'', ''x'', %L)', org_b, seller_a)) like '%bevicred_link_target_not_in_company%' from ids;
insert into results select 'seller id as a table refused',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''table'', ''y'', ''y'', %L)', org_a, seller_a)) like '%bevicred_link_target_not_in_company%' from ids;
insert into results select 'one link per key',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''table'', ''inss ml dweb tkt'', ''again'', %L)', org_a, table_a)) like '%duplicate key%' from ids;
insert into results select 'unknown kind refused',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''bank'', ''z'', ''z'', %L)', org_a, table_a)) like '%check constraint%' from ids;

set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
insert into results values ('admin cannot read links', pg_temp.err('select count(*) from public.bevicred_links') like '%permission denied%');
insert into results select 'admin cannot write links',
  pg_temp.err(format('insert into public.bevicred_links (organization_id, kind, external_key, external_label, target_id) values (%L, ''table'', ''w'', ''w'', %L)', org_a, table_a)) like '%permission denied%' from ids;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where ok is not true) then raise exception 'bevicred links contract failed'; end if;
  if (select count(*) from results) < 10 then raise exception 'bevicred links contract incomplete'; end if;
end $$;

rollback;
