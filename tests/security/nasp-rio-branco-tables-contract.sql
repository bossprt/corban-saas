-- Contract test for 20261004004850_nasp_rio_branco_tables_v1: the four NASP - Prefeitura de Rio Branco tables are
-- published with vigência from 01/01/2026, one Novo and one Refinanciamento line each, the commission (net amount) and
-- payout by group of the Governo do Acre tables, and running it again changes nothing.
-- One transaction, rolled back. The migration file must be reachable at /tmp/nasp_rb.sql:
--   docker cp supabase/migrations/20261004004850_nasp_rio_branco_tables_v1.sql <db>:/tmp/nasp_rb.sql
--   psql -v ON_ERROR_STOP=1 -f tests/security/nasp-rio-branco-tables-contract.sql

begin;

create temp table results (check_name text, ok boolean);

-- No agreement Prefeitura de Rio Branco next to the bank NASP: nothing happens.
delete from public.organization_agreements a where a.name = 'Prefeitura de Rio Branco'
  and not exists (select 1 from public.organization_product_routes r where r.org_agreement_id = a.id);
\i /tmp/nasp_rb.sql
insert into results select 'no agreement: nothing changes', not exists (select 1 from public.product_tables where code like 'nasp-rb-%');

-- The company shaped like production: bank NASP, agreement Prefeitura de Rio Branco and the five commission groups.
create temp table co as
select m.organization_id as org from public.organization_memberships m
where m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
insert into public.organization_banks (organization_id, tech_key, name)
select org, 'nasp', 'NASP' from co where not exists (select 1 from public.organization_banks b, co where b.organization_id = co.org and b.name = 'NASP');
insert into public.organization_agreements (organization_id, name) select org, 'Prefeitura de Rio Branco' from co;
insert into public.commission_groups (organization_id, name)
select org, g from co, unnest(array['Balcão', 'Corretor', 'Parceiro', 'Call Center', 'Afiliado']) g
on conflict do nothing;

\i /tmp/nasp_rb.sql

create temp table got as
select t.code, t.name, t.status as table_status, t.formalization, v.status as version_status,
  (v.effective_from at time zone 'America/Sao_Paulo')::date as valid_from_date, ct.tech_key, c.term_min, c.term_max, c.rate, c.amount_min,
  k.received_value, k.calculation_base, a.name as agreement,
  (select jsonb_object_agg(g.name, gv.value::numeric) from public.commercial_condition_group_values gv join public.commission_groups g on g.id = gv.group_id
   where gv.condition_id = c.id) as groups
from public.product_tables t
join public.organization_product_routes r on r.id = t.route_id
join public.organization_agreements a on a.id = r.org_agreement_id
join public.product_table_versions v on v.product_table_id = t.id
join public.commercial_conditions c on c.product_table_version_id = v.id
join public.contract_types ct on ct.id = c.contract_type_id
left join public.commercial_condition_components k on k.condition_id = c.id
where t.code like 'nasp-rb-%';

insert into results select 'four tables, published, agreement Prefeitura de Rio Branco',
  count(distinct code) = 4 and bool_and(table_status = 'active' and version_status = 'published' and agreement = 'Prefeitura de Rio Branco') from got;
insert into results select 'two lines per table: novo and refinanciamento',
  count(*) = 8 and count(*) filter (where tech_key = 'novo') = 4 and count(*) filter (where tech_key = 'refinanciamento') = 4 from got;
insert into results select 'vigência 01/01/2026', bool_and(valid_from_date = date '2026-01-01') from got;
insert into results select 'terms as the list', bool_and(case
  when code like '%-4-7' then term_min = 4 and term_max = 7
  when code = 'nasp-rb-temporario-8-18' then term_min = 8 and term_max = 18
  else term_min = 8 and term_max = 24 end) from got;
insert into results select 'rate 0, no amount range', bool_and(rate = 0 and amount_min is null) from got;
insert into results select 'commission on the net amount: 6% on 4-7, 10% on the rest',
  bool_and(calculation_base = 'LÍQUIDO' and received_value::numeric = case when term_max = 7 then 6 else 10 end) from got;
insert into results select 'payout 6% tables as Governo do Acre',
  bool_and(groups = '{"Balcão":3,"Call Center":1.5,"Afiliado":0.6,"Corretor":2,"Parceiro":2}'::jsonb) from got where term_max = 7;
insert into results select 'payout 10% tables as Governo do Acre',
  bool_and(groups = '{"Balcão":5,"Call Center":2.5,"Afiliado":1,"Corretor":4,"Parceiro":4}'::jsonb) from got where term_max <> 7;
insert into results select 'names keep "Prefeitura ..."', bool_and(name like 'NASP - Pref. Rio Branco - Prefeitura %') from got;

\i /tmp/nasp_rb.sql
insert into results select 'second run changes nothing', count(*) = 4 from public.product_tables where code like 'nasp-rb-%';

select check_name, ok from results order by ok, check_name;
do $$ begin if exists (select 1 from results where not ok) then raise exception 'nasp rio branco contract failed'; end if; end $$;
rollback;
