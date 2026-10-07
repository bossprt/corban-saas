-- Contract test for 20261007_fintech_corban_tables_v1: in a company with the bank FINTECH CORBAN and the agreements
-- FGTS, INSS and CLT Privado, the migration publishes 35 tables and 61 lines with the export's ranges, base and payout;
-- a second run does nothing; a contract on BFFUNDO takes the line of its amount. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -v mig=supabase/migrations/20261007_fintech_corban_tables_v1.sql -f tests/security/fintech-corban-tables-contract.sql

begin;

create temp table results (check_name text, ok boolean);
create temp table ids as select '00000000-0000-4000-8000-00000000c0b1'::uuid as org;

-- Fixture: the bank and the three agreements in the test company.
insert into public.organization_banks (organization_id, name, is_active) select org, 'FINTECH CORBAN', true from ids;
insert into public.organization_agreements (organization_id, name, is_active) select org, x, true from ids, unnest(array['FGTS', 'INSS', 'CLT Privado']) x;

\i :mig

create temp table t as
select t.id table_id, t.code, t.name, v.id version_id, v.status, v.effective_from, v.metadata, a.name agreement
from public.product_tables t join public.product_table_versions v on v.product_table_id = t.id
join public.organization_product_routes r on r.id = t.route_id join public.organization_agreements a on a.id = r.org_agreement_id
where t.organization_id = (select org from ids) and t.code like 'fintech-%';

insert into results select '35 tables, all published', count(*) = 35 and bool_and(status = 'published') from t;
insert into results select '61 lines', (select count(*) from public.commercial_conditions k where k.product_table_version_id in (select version_id from t)) = 61;
insert into results select 'agreements: 12 FGTS, 2 CLT Privado, 21 INSS',
  (select count(*) from t where agreement = 'FGTS') = 12 and (select count(*) from t where agreement = 'CLT Privado') = 2 and (select count(*) from t where agreement = 'INSS') = 21;
insert into results select 'one own-production route per agreement',
  (select count(distinct t2.route_id) from public.product_tables t2 where t2.id in (select table_id from t)) = 3;
insert into results select 'bank ids kept', (select metadata->>'external_table_code' = '43015' and metadata->>'bank_main_table_id' = '632' from t where code = 'fintech-43015');
insert into results select 'BFFUNDO bands: 45 / 35 / 20.5 / 18.5 up to 49.999,99 / nothing at 50.000',
  (select string_agg(k.amount_min || '-' || k.amount_max || ':' || coalesce(trim_scale(c.received_value)::text, 'none'), ' ' order by k.amount_min)
   from public.commercial_conditions k left join public.commercial_condition_components c on c.condition_id = k.id
   where k.product_table_version_id = (select version_id from t where code = 'fintech-43015'))
  = '40.00-150.00:45 150.01-250.00:35 250.01-600.00:20.5 600.01-49999.99:18.5 50000.00-50000.00:none';
insert into results select 'Port + Refin is gross and Refin/Portabilidade',
  (select bool_and(upper(c.calculation_base) = 'BRUTO' and ct.tech_key = 'refin_portabilidade')
   from t join public.commercial_conditions k on k.product_table_version_id = t.version_id
   join public.commercial_condition_components c on c.condition_id = k.id join public.contract_types ct on ct.id = k.contract_type_id
   where t.name like 'PORT + REFIN%');
insert into results select 'INSS Novo without base in the export is net',
  (select bool_and(upper(c.calculation_base) like 'L%')
   from t join public.commercial_conditions k on k.product_table_version_id = t.version_id
   join public.commercial_condition_components c on c.condition_id = k.id where t.code = 'fintech-43025');
insert into results select 'Corretor 65% of 18,5% = 12,025% and Afiliado 1,85% (exact)',
  (select bool_and(case g.name when 'Corretor' then gv.value = 12.025 when 'Afiliado' then gv.value = 1.85 else true end) and count(*) = 5
   from public.commercial_conditions k join public.commercial_condition_group_values gv on gv.condition_id = k.id
   join public.commission_groups g on g.id = gv.group_id
   where k.product_table_version_id = (select version_id from t where code = 'fintech-43015') and k.amount_min = 600.01);
insert into results select 'no tax on any line',
  not exists (select 1 from public.commercial_conditions k where k.product_table_version_id in (select version_id from t) and k.tax_pct <> 0);
insert into results select 'start date from the export (FIXO 15: 03/09/2026)',
  (select (effective_from at time zone 'America/Sao_Paulo')::date = date '2026-09-03' from t where code = 'fintech-43018');

-- A Corretor contract of R$ 200 on BFFUNDO takes the 35% line and pays 65% of it; one of R$ 50.000 takes the 0% line.
-- The group's rule as in production: the seller gets 100% of the group value of the line ("own").
select set_config('corban.group_rule_rpc', 'on', true);
with g as (select id from public.commission_groups where organization_id = (select org from ids) and name = 'Corretor'),
     r as (insert into public.commission_group_rules (organization_id, group_id, version, own_production, supervisor_basis, supervisor_pct, manager_basis, manager_pct)
           select (select org from ids), g.id, 1, false, 'spread', 0, 'spread', 0 from g
           where not exists (select 1 from public.commission_group_rules x where x.group_id = g.id) returning id)
insert into public.commission_group_rule_items (rule_id, organization_id, component_type_id, reference_kind, distributed_pct)
select r.id, (select org from ids), k.id, 'own', 100 from r, public.commission_component_types k where k.is_active;
select set_config('corban.group_rule_rpc', 'off', true);
update public.commercial_sellers set commission_group_id = (select id from public.commission_groups where organization_id = (select org from ids) and name = 'Corretor')
where id = '00000000-0000-4000-8000-0000000c0802';
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
grant select on ids, t to authenticated;
select set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where email = 'admin@corban-teste.local'), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Fintech', '68999770019', null, 'manual') u;
insert into made select 'p200', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select version_id from t where code = 'fintech-43015'), '00000000-0000-4000-8000-0000000c0802', 200, 200, 20, 12, 'ADE-FINTECH-200', 'submitted',
  (select id from public.contract_types where tech_key = 'novo' and organization_id is null), null) d;
insert into made select 'p50k', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select version_id from t where code = 'fintech-43015'), '00000000-0000-4000-8000-0000000c0802', 50000, 50000, 900, 84, 'ADE-FINTECH-50K', 'submitted',
  (select id from public.contract_types where tech_key = 'novo' and organization_id is null), null) d;
set constraints all immediate;  -- the contract is calculated at commit
reset role;
insert into results select 'R$ 200 on BFFUNDO: 35% line, company R$ 70,00, Corretor R$ 45,50',
  (select k.amount_min = 150.01 from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
   where x.proposal_id = (select id from made where label = 'p200') and x.status = 'active')
  and (select coalesce(sum(payable), 0) from private.contract_payable((select id from made where label = 'p200'))) = 45.50;
insert into results select 'R$ 50.000 on BFFUNDO: 0% line, nothing to pay',
  (select k.amount_min = 50000 from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
   where x.proposal_id = (select id from made where label = 'p50k') and x.status = 'active')
  and (select coalesce(sum(payable), 0) from private.contract_payable((select id from made where label = 'p50k'))) = 0;
select set_config('request.jwt.claims', '', true);

-- A second run changes nothing.
\i :mig
insert into results select 'second run does nothing',
  (select count(*) from public.product_tables x where x.organization_id = (select org from ids) and x.code like 'fintech-%') = 35;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'fintech corban tables contract failed'; end if;
end $$;
rollback;
