-- Contract test for 20261006_nasp_acre_refin_lines_v1: the four NASP Governo do Acre Temporário and Comissionado tables
-- get a Refinanciamento line equal to the Novo line (component and payout per group), in a v2 published from
-- 01/01/2026; v1 stays as superseded history; running it again adds nothing.
-- Needs the local NASP Acre fixture (bank, agreement, groups and 20261002122145_nasp_acre_tables_v1). Rolled back.
--   docker cp supabase/migrations/20261006_nasp_acre_refin_lines_v1.sql <db>:/tmp/nasp_acre_refin.sql
--   psql -v ON_ERROR_STOP=1 -f tests/security/nasp-acre-refin-contract.sql

begin;
\i /tmp/nasp_acre_refin.sql
\i /tmp/nasp_acre_refin.sql

create temp table results (check_name text, ok boolean);
create temp view lines as
select t.code, v.version, v.status, v.effective_from, ct.tech_key, c.id, c.term_min, c.term_max, c.rate, c.tax_pct,
  (select string_agg(concat_ws('|', k.component_type_id, k.value_kind, k.received_value, k.calculation_base), ',' order by k.component_type_id) from public.commercial_condition_components k where k.condition_id = c.id) comp,
  (select string_agg(concat_ws('|', g.group_id, g.component_type_id, g.value_kind, g.value), ',' order by g.group_id) from public.commercial_condition_group_values g where g.condition_id = c.id) grp
from public.product_tables t join public.product_table_versions v on v.product_table_id = t.id
join public.commercial_conditions c on c.product_table_version_id = v.id join public.contract_types ct on ct.id = c.contract_type_id
where t.code in ('nasp-ac-temporario-4-7', 'nasp-ac-temporario-8-18', 'nasp-ac-comissionado-4-7', 'nasp-ac-comissionado-8-24');

insert into results select 'four tables: v2 published from 01/01/2026, v1 superseded',
  (select count(*) = 4 from public.product_tables t join public.product_table_versions v on v.product_table_id = t.id
   where t.code like 'nasp-ac-%' and t.code not like 'nasp-ac-efetivo%' and v.version = 2 and v.status = 'published'
     and (v.effective_from at time zone 'America/Sao_Paulo')::date = date '2026-01-01')
  and (select count(*) = 4 from public.product_tables t join public.product_table_versions v on v.product_table_id = t.id
   where t.code like 'nasp-ac-%' and t.code not like 'nasp-ac-efetivo%' and v.version = 1 and v.status = 'superseded');
insert into results select 'each v2 has one Novo and one Refinanciamento line, nothing else',
  (select count(*) = 4 from (select code from lines where version = 2 group by code
     having count(*) = 2 and count(*) filter (where tech_key = 'novo') = 1 and count(*) filter (where tech_key = 'refinanciamento') = 1) x);
insert into results select 'Refinanciamento equals Novo: terms, rate, tax, component and payout per group',
  not exists (select 1 from lines n join lines r on r.code = n.code and r.version = 2 and r.tech_key = 'refinanciamento'
              where n.version = 2 and n.tech_key = 'novo'
                and (r.term_min, r.term_max, r.rate, r.tax_pct, r.comp, r.grp) is distinct from (n.term_min, n.term_max, n.rate, n.tax_pct, n.comp, n.grp))
  and (select count(*) = 4 from lines where version = 2 and tech_key = 'refinanciamento' and grp is not null and comp is not null);
insert into results select 'Efetivo tables untouched (one version each)',
  (select count(*) = 3 from public.product_tables t where t.code like 'nasp-ac-efetivo%'
     and (select count(*) from public.product_table_versions v where v.product_table_id = t.id) = 1);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'nasp acre refin contract failed'; end if;
end $$;
rollback;
