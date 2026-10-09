-- Contract test for 20261009_table_bank_code_auto_v1: a table created later gets the bank's code by itself (from the
-- system code ending in the number, or the name starting with it); a typed code is kept; a name without a number gives
-- no code; the Fator Price import then finds the new table. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/table-bank-code-auto-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
create temp table results (check_name text, ok boolean);
select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);

insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco Código', true from ids returning id \gset bank_
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio Código', true from ids returning id \gset agr_
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, :'bank_id', :'agr_id', 'own', 'active' from ids returning id \gset route_

insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'auto-a', '833001 - GOV TESTE 1 DIG', 'active', 'digital' from ids;
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'mv-833002', 'TABELA SEM NUMERO', 'active', 'digital' from ids;
insert into public.product_tables (organization_id, route_id, code, name, status, formalization, bank_table_code)
select org, :'route_id', 'auto-c', '833003 - OUTRA', 'active', 'digital', 'MANUAL-9' from ids;
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'auto-d', 'EMPRÉSTIMO - 2.70%', 'active', 'digital' from ids;

insert into results select 'from the name starting with the number', (select bank_table_code = '833001' from public.product_tables where code = 'auto-a');
insert into results select 'from the system code ending in the number', (select bank_table_code = '833002' from public.product_tables where code = 'mv-833002');
insert into results select 'a typed code is kept', (select bank_table_code = 'MANUAL-9' from public.product_tables where code = 'auto-c');
insert into results select 'no number, no code', (select bank_table_code is null from public.product_tables where code = 'auto-d');
update public.product_tables set name = '899999 - RENOMEADA' where code = 'auto-a';
insert into results select 'renaming does not replace an existing code', (select bank_table_code = '833001' from public.product_tables where code = 'auto-a');

-- The Fator Price import finds the new table by the code.
insert into results select 'the Fator Price import finds the new table',
  (public.import_factor_price((select org from ids), :'bank_id', :'agr_id',
     jsonb_build_array(jsonb_build_object('code', '833001', 'dates', jsonb_build_array(jsonb_build_object('date', '2026-12-01', 'entries', jsonb_build_array(jsonb_build_object('term', 120, 'factor', '0.025'))))))))->>'profiles_created' = '1';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'table bank code auto contract failed'; end if;
end $$;
rollback;
