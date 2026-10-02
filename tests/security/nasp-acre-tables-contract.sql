-- Contract test for 20261002052952_nasp_acre_tables_v1: the seven NASP - Governo do Acre tables are published with
-- vigência from 01/01/2026, the commission and payout by group the owner gave, and running it again changes nothing.
-- One transaction, rolled back. The migration file must be reachable at /tmp/nasp_acre.sql:
--   docker cp supabase/migrations/20261002052952_nasp_acre_tables_v1.sql <db>:/tmp/nasp_acre.sql
--   psql -v ON_ERROR_STOP=1 -f tests/security/nasp-acre-tables-contract.sql

begin;

create temp table results (check_name text, ok boolean);

-- No NASP bank: nothing happens.
\i /tmp/nasp_acre.sql
insert into results select 'no NASP bank: nothing changes',
  not exists (select 1 from public.product_tables where code like 'nasp-ac-%');

-- The company shaped like production: bank NASP, agreement Governo do Acre and the five commission groups.
create temp table co as
select m.organization_id as org from public.organization_memberships m
where m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
insert into public.organization_banks (organization_id, tech_key, name) select org, 'nasp', 'NASP' from co;
insert into public.organization_agreements (organization_id, name) select org, 'Governo do Acre' from co;
insert into public.commission_groups (organization_id, name)
select org, g from co, unnest(array['Balcão', 'Corretor', 'Parceiro', 'Call Center', 'Afiliado']) g
on conflict do nothing;

\i /tmp/nasp_acre.sql

create temp table got as
select t.code, t.status as table_status, v.status as version_status, (v.effective_from at time zone 'America/Sao_Paulo')::date as valid_from_date, ct.tech_key, c.term_min, c.term_max, c.rate,
  c.amount_min, k.received_value,
  (select jsonb_object_agg(g.name, gv.value::numeric) from public.commercial_condition_group_values gv join public.commission_groups g on g.id = gv.group_id
   where gv.condition_id = c.id) as groups
from public.product_tables t
join public.product_table_versions v on v.product_table_id = t.id
join public.commercial_conditions c on c.product_table_version_id = v.id
join public.contract_types ct on ct.id = c.contract_type_id
left join public.commercial_condition_components k on k.condition_id = c.id
where t.code like 'nasp-ac-%';

insert into results select 'seven tables, one published line each', count(*) = 7 and count(distinct code) = 7
  and bool_and(table_status = 'active' and version_status = 'published') from got;
insert into results select 'vigência 01/01/2026', bool_and(valid_from_date = date '2026-01-01') from got;
insert into results select 'contract types: novo x5, refinanciamento, compra de dívida',
  count(*) filter (where tech_key = 'novo') = 5
  and exists (select 1 from got where code = 'nasp-ac-efetivo-refin' and tech_key = 'refinanciamento')
  and exists (select 1 from got where code = 'nasp-ac-efetivo-compra' and tech_key = 'compra_de_divida') from got;
insert into results select 'terms as the list', bool_and(case code
  when 'nasp-ac-temporario-4-7' then term_min = 4 and term_max = 7
  when 'nasp-ac-temporario-8-18' then term_min = 8 and term_max = 18
  when 'nasp-ac-comissionado-4-7' then term_min = 4 and term_max = 7
  when 'nasp-ac-comissionado-8-24' then term_min = 8 and term_max = 24
  else term_min = 24 and term_max = 84 end) from got;
insert into results select 'no amount range; rate 0 or empty as the list',
  bool_and(amount_min is null) and bool_and(case when term_min = 24 then rate is null else rate = 0 end) from got;
insert into results select 'commission 6% on 4-7, 10% on the rest',
  bool_and(received_value::numeric = case when term_max = 7 then 6 else 10 end) from got;
insert into results select 'payout 6% tables: Balcão 3, Call Center 1,5, Afiliado 0,6, Corretor 2, Parceiro 2',
  bool_and(groups = '{"Balcão":3,"Call Center":1.5,"Afiliado":0.6,"Corretor":2,"Parceiro":2}'::jsonb) from got where term_max = 7;
insert into results select 'payout 10% tables: Balcão 5, Call Center 2,5, Afiliado 1, Corretor 4, Parceiro 4',
  bool_and(groups = '{"Balcão":5,"Call Center":2.5,"Afiliado":1,"Corretor":4,"Parceiro":4}'::jsonb) from got where term_max <> 7;

-- Running it again does nothing.
\i /tmp/nasp_acre.sql
insert into results select 'second run changes nothing', count(*) = 7 from public.product_tables where code like 'nasp-ac-%';

select check_name, ok from results order by ok, check_name;
do $$ begin if exists (select 1 from results where not ok) then raise exception 'nasp acre contract failed'; end if; end $$;
rollback;
