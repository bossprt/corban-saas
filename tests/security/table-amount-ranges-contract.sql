-- Contract test for 20261007194442_table_amount_ranges_v1: the import keeps the amount bands of one table apart (found by
-- term and amount range, re-import updates in place), takes lines without rate and refuses a half range; the
-- commission engine matches a net line's band on the released amount and a gross line's band on the contract's
-- amount. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/table-amount-ranges-contract.sql

begin;

create temp table results (check_name text, ok boolean);
create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       '00000000-0000-4000-8000-0000000c0802'::uuid as seller,
       (select id from public.commission_component_types where tech_key = 'upfront') as avista,
       (select id from public.contract_types where tech_key = 'novo' and organization_id is null) as novo,
       (select id from public.commission_groups where organization_id = '00000000-0000-4000-8000-00000000c0b1' and name = 'Corretor') as corretor;
grant select on ids to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
-- One import row: a band of the table "Faixas Teste" (net or gross), term 12, À Vista for the company and Corretor.
create function pg_temp.row(p_min numeric, p_max numeric, p_pct text, p_corretor text, p_base text) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'bank_name', 'Banco Faixas', 'agreement_name', 'Convênio Faixas', 'table_name', 'Faixas Teste ' || p_base,
    'contract_type_id', (select novo from ids), 'term', 12, 'amount_min', p_min, 'amount_max', p_max, 'tax_pct', '0',
    'components', jsonb_build_array(jsonb_build_object('component_type_id', (select avista from ids), 'value_kind', 'percentage',
                                    'received_value', p_pct, 'source', 'import', 'calculation_base', p_base)),
    'group_values', jsonb_build_array(jsonb_build_object('group_id', (select corretor from ids), 'component_type_id', (select avista from ids),
                                      'value_kind', 'percentage', 'value', p_corretor, 'source', 'import'))));
$$;
grant execute on function pg_temp.row(numeric, numeric, text, text, text) to authenticated;

-- The Corretor group's rule as in production (100% of the group value of the line), and the test seller in it.
select set_config('corban.group_rule_rpc', 'on', true);
with r as (insert into public.commission_group_rules (organization_id, group_id, version, own_production, supervisor_basis, supervisor_pct, manager_basis, manager_pct)
           select org, corretor, 1, false, 'spread', 0, 'spread', 0 from ids
           where not exists (select 1 from public.commission_group_rules x where x.group_id = (select corretor from ids)) returning id)
insert into public.commission_group_rule_items (rule_id, organization_id, component_type_id, reference_kind, distributed_pct)
select r.id, (select org from ids), k.id, 'own', 100 from r, public.commission_component_types k where k.is_active;
select set_config('corban.group_rule_rpc', 'off', true);
update public.commercial_sellers set commission_group_id = (select corretor from ids) where id = (select seller from ids);

select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;

-- Import: three net bands and one gross band, no rate in any row.
insert into results select 'import takes the bands without rate',
  pg_temp.err(format('select public.import_smart_commercial_rows(%L, %L, null, null, %L)', (select org from ids), 'own',
    jsonb_build_array(pg_temp.row(40, 150, '45', '29.25', 'LÍQUIDO'), pg_temp.row(150.01, 250, '35', '22.75', 'LÍQUIDO'),
                      pg_temp.row(250.01, 600, '20.5', '13.325', 'LÍQUIDO'), pg_temp.row(5000, 125000, '5.5', '3.575', 'BRUTO')))) = 'ok';
-- The same file again updates the bands in place (one band changes value).
insert into results select 're-import updates the bands in place',
  pg_temp.err(format('select public.import_smart_commercial_rows(%L, %L, null, null, %L)', (select org from ids), 'own',
    jsonb_build_array(pg_temp.row(40, 150, '46', '29.9', 'LÍQUIDO'), pg_temp.row(150.01, 250, '35', '22.75', 'LÍQUIDO'),
                      pg_temp.row(250.01, 600, '20.5', '13.325', 'LÍQUIDO')))) = 'ok';
insert into results select 'a half range is refused',
  pg_temp.err(format('select public.import_smart_commercial_rows(%L, %L, null, null, %L)', (select org from ids), 'own',
    jsonb_build_array(pg_temp.row(40, null, '45', '29.25', 'LÍQUIDO')))) like '%invalid_smart_import_row%';
insert into results select 'an inverted range is refused',
  pg_temp.err(format('select public.import_smart_commercial_rows(%L, %L, null, null, %L)', (select org from ids), 'own',
    jsonb_build_array(pg_temp.row(600, 40, '45', '29.25', 'LÍQUIDO')))) like '%invalid_smart_import_row%';
reset role;

insert into made select 'net_version', v.id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
where t.organization_id = (select org from ids) and t.name = 'Faixas Teste LÍQUIDO' and v.status = 'draft';
insert into made select 'gross_version', v.id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
where t.organization_id = (select org from ids) and t.name = 'Faixas Teste BRUTO' and v.status = 'draft';
insert into results select 'three net bands, kept apart, the first updated, no rate',
  (select count(*) = 3 and bool_and(k.rate is null and k.coefficient is null)
     and string_agg(k.amount_min || '-' || k.amount_max || ':' || trim_scale(c.received_value), ' ' order by k.amount_min) = '40.00-150.00:46 150.01-250.00:35 250.01-600.00:20.5'
   from public.commercial_conditions k join public.commercial_condition_components c on c.condition_id = k.id
   where k.product_table_version_id = (select id from made where label = 'net_version'));

-- Contracts: publish both tables and register three contracts as the admin.
select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
select public.publish_product_table_version((select id from made where label = 'net_version'), date '2026-01-01');
select public.publish_product_table_version((select id from made where label = 'gross_version'), date '2026-01-01');
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Faixas', '68999770019', null, 'manual') u;
-- Net line: contract R$ 160 (band 150,01-250 by the contract's amount) but R$ 140 released (band 40-150).
insert into made select 'net', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'net_version'), (select seller from ids), 160, 140, 20, 12, 'ADE-FAIXA-NET', 'submitted', (select novo from ids), null) d;
-- Gross line: contract R$ 5.000 (inside 5.000-125.000) with R$ 4.000 released: the contract's amount decides.
insert into made select 'gross', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'gross_version'), (select seller from ids), 5000, 4000, 200, 12, 'ADE-FAIXA-GROSS', 'submitted', (select novo from ids), null) d;
-- Gross line: contract R$ 4.000 with R$ 5.000 "released" stays out of the band (no line, the reason is recorded).
insert into made select 'gross_out', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'gross_version'), (select seller from ids), 4000, 5000, 200, 12, 'ADE-FAIXA-OUT', 'submitted', (select novo from ids), null) d;
set constraints all immediate;  -- contracts are calculated at commit
reset role;

insert into results select 'net line: band of the released amount (R$ 140 in 40-150, 46%), Corretor 29,9% of 140 = R$ 41,86',
  (select k.amount_min = 40 from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
   where x.proposal_id = (select id from made where label = 'net') and x.status = 'active')
  and (select coalesce(sum(payable), 0) from private.contract_payable((select id from made where label = 'net'))) = 41.86;
insert into results select 'gross line: band of the contract amount (R$ 5.000), Corretor 3,575% of 5.000 = R$ 178,75',
  (select coalesce(sum(payable), 0) from private.contract_payable((select id from made where label = 'gross'))) = 178.75;
insert into results select 'gross line: R$ 4.000 contract is out of the band even with R$ 5.000 released',
  not exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = (select id from made where label = 'gross_out'))
  and exists (select 1 from public.contract_events e where e.proposal_id = (select id from made where label = 'gross_out') and e.kind = 'calc_failed' and e.detail->>'code' = 'condition_not_found');
insert into results select 'lines without range still take any amount',
  private.condition_amount_fits(gen_random_uuid(), null, null, 1, 1);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'table amount ranges contract failed'; end if;
end $$;
rollback;
