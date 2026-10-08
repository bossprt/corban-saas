-- Contract test for 20261008060304_simulator_offers_v1: the agreement's tables are compared; only tables with a factor appear
-- (daily factor of the date, fixed factor, or the table line's coefficient); installment = amount x factor and amount =
-- installment / factor (cut down to the cent); refin change = amount - balance; the chosen offer is recalculated and
-- saved as a simulation that becomes a proposal; another company is refused. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/simulator-offers-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from public.contract_types where tech_key = 'novo' and organization_id is null) as novo,
       (select id from public.contract_types where tech_key = 'refinanciamento' and organization_id is null) as refin,
       (now() at time zone 'America/Sao_Paulo')::date as today;
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

select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);

-- Catalog: one agreement, one bank, three tables (daily factor, fixed factor, no factor) + one table line coefficient.
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio Simulador', true from ids returning id \gset agr_
insert into made values ('agreement', :'agr_id');
insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco Simulador', true from ids returning id \gset bank_
insert into made values ('bank', :'bank_id');
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, (select id from made where label = 'bank'), (select id from made where label = 'agreement'), 'own', 'active' from ids returning id \gset route_

create function pg_temp.table_with_line(p_code text, p_name text, p_coef numeric, p_min numeric, p_max numeric) returns uuid language plpgsql as $$
declare t uuid; v uuid;
begin
  insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
  values ((select org from ids), (select id from public.organization_product_routes where org_agreement_id = (select id from made where label = 'agreement')),
          p_code, p_name, 'active', 'digital') returning id into t;
  insert into public.product_table_versions (organization_id, product_table_id, version, status) values ((select org from ids), t, 1, 'draft') returning id into v;
  insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, coefficient, tax_pct)
  values ((select org from ids), v, (select novo from ids), 72, 72, 96, p_min, p_max, p_coef, 0),
         ((select org from ids), v, (select refin from ids), 72, 72, 96, p_min, p_max, p_coef, 0);
  perform public.publish_product_table_version(v, (select today from ids) - 1);
  insert into made values (p_code, v), (p_code || '_table', t);
  return v;
end $$;
select pg_temp.table_with_line('sim-daily', 'Tabela Diária', null, null, null);
select pg_temp.table_with_line('sim-fixed', 'Tabela Fixa', null, null, null);
select pg_temp.table_with_line('sim-none', 'Tabela Sem Fator', null, null, null);
select pg_temp.table_with_line('sim-coef', 'Tabela Coeficiente', 0.0250, null, null);

-- Factors: daily for the first table (today's batch), fixed for the second (published yesterday).
insert into public.commercial_factor_profiles (organization_id, tech_key, name, org_bank_id, org_agreement_id, product_table_id, factor_mode, is_active)
select org, 'sim-daily', 'Diário', (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select id from made where label = 'sim-daily_table'), 'daily', true from ids returning id \gset pd_
insert into public.commercial_factor_profiles (organization_id, tech_key, name, org_bank_id, org_agreement_id, product_table_id, factor_mode, is_active)
select org, 'sim-fixed', 'Fixo', (select id from made where label = 'bank'), (select id from made where label = 'agreement'), (select id from made where label = 'sim-fixed_table'), 'fixed', true from ids returning id \gset pf_
insert into public.commercial_factor_batches (organization_id, profile_id, effective_date, revision, status, source_kind)
select org, :'pd_id', today, 1, 'draft', 'manual' from ids returning id \gset bd_
insert into public.commercial_factor_entries (organization_id, batch_id, term_min, term_max, factor_value) select org, :'bd_id', 72, 96, 0.0225 from ids;
select public.publish_commercial_factor_batch(:'bd_id');
insert into public.commercial_factor_batches (organization_id, profile_id, effective_date, revision, status, source_kind)
select org, :'pf_id', today - 1, 1, 'draft', 'manual' from ids returning id \gset bf_
insert into public.commercial_factor_entries (organization_id, batch_id, term_min, term_max, factor_value) select org, :'bf_id', 72, 96, 0.0230 from ids;
select public.publish_commercial_factor_batch(:'bf_id');

set local role authenticated;
insert into seen select 'amount', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 84, 'amount', 10000);
insert into seen select 'installment', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 84, 'installment', 300);
insert into seen select 'refin', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select refin from ids), 84, 'amount', 10000, 6000);
insert into seen select 'yesterday', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 84, 'amount', 10000, null, (select today from ids) - 1);
insert into seen select 'out_of_term', public.simulation_offers((select org from ids), (select id from made where label = 'agreement'), (select novo from ids), 120, 'amount', 10000);
insert into results select 'another company is refused',
  pg_temp.err(format('select public.simulation_offers(%L, %L, %L, 84, %L, 1000)', gen_random_uuid(), (select id from made where label = 'agreement'), (select novo from ids), 'amount')) like '%not_authorized%';
reset role;

insert into results select 'only the three tables with a factor appear (no-factor table hidden)',
  (select jsonb_array_length(b) = 3 and not b @> '[{"table_name":"Tabela Sem Fator"}]' from seen where label = 'amount');
insert into results select 'by amount: installment = 10.000 x factor, lowest first (225,00 daily; 230,00 fixed; 250,00 coefficient)',
  (select string_agg((e->>'table_name') || '=' || (e->>'installment') || '/' || (e->>'factor_source'), ' ' order by ord)
   from seen, jsonb_array_elements(b) with ordinality as x(e, ord) where label = 'amount')
  = 'Tabela Diária=225.00/daily Tabela Fixa=230.00/fixed Tabela Coeficiente=250.00/table';
insert into results select 'by installment: amount = 300 / factor cut to the cent, highest first (13.333,33; 13.043,47; 12.000,00)',
  (select string_agg((e->>'amount'), ' ' order by ord) from seen, jsonb_array_elements(b) with ordinality as x(e, ord) where label = 'installment')
  = '13333.33 13043.47 12000.00';
insert into results select 'refin: change = amount - balance (4.000,00)',
  (select bool_and((e->>'change')::numeric = 4000.00 and (e->>'outstanding')::numeric = 6000.00) from seen, jsonb_array_elements(b) e where label = 'refin');
insert into results select 'the daily factor counts only on its date (yesterday: daily table gone)',
  (select jsonb_array_length(b) = 2 and not b @> '[{"table_name":"Tabela Diária"}]' from seen where label = 'yesterday');
insert into results select 'a term outside the table gives nothing', (select b = '[]'::jsonb from seen where label = 'out_of_term');

-- Saving the chosen offer: recalculated, saved, becomes a proposal.
select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Simulador', '68999770031', null, 'manual') u;
insert into made select 'sim', public.save_simulation_offer((select id from made where label = 'client'), (select id from made where label = 'sim-daily'),
  (select (e->>'condition_id')::uuid from seen, jsonb_array_elements(b) e where label = 'refin' and e->>'table_name' = 'Tabela Diária'),
  (select id from made where label = 'agreement'), (select refin from ids), 84, 'amount', 10000, 6000);
insert into results select 'a balance above the amount is refused',
  pg_temp.err(format('select public.save_simulation_offer(%L, %L, %L, %L, %L, 84, %L, 1000, 6000)', (select id from made where label = 'client'), (select id from made where label = 'sim-daily'),
    (select (e->>'condition_id')::uuid from seen, jsonb_array_elements(b) e where label = 'refin' and e->>'table_name' = 'Tabela Diária'),
    (select id from made where label = 'agreement'), (select refin from ids), 'amount')) like '%outstanding_above_amount%';
insert into results select 'a table without factor cannot be saved',
  pg_temp.err(format('select public.save_simulation_offer(%L, %L, (select id from public.commercial_conditions where product_table_version_id = %L limit 1), %L, %L, 84, %L, 10000)',
    (select id from made where label = 'client'), (select id from made where label = 'sim-none'), (select id from made where label = 'sim-none'),
    (select id from made where label = 'agreement'), (select novo from ids), 'amount')) like '%offer_not_available%';
insert into made select 'proposal', public.create_proposal_from_simulation((select id from made where label = 'sim'));
reset role;

insert into results select 'saved simulation: contract 10.000, released 4.000 (change), installment 225, factor 0,0225',
  (select requested_amount = 10000 and released_amount = 4000 and installment_amount = 225 and coefficient = 0.0225 and status in ('calculated', 'selected')
   from public.simulations where id = (select id from made where label = 'sim'));
insert into results select 'the proposal carries the simulation (amounts, term, refin type)',
  (select requested_amount = 10000 and released_amount = 4000 and installment_amount = 225 and term = 84 and contract_type_id = (select refin from ids)
   from public.proposals_v2 where id = (select id from made where label = 'proposal'));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'simulator offers contract failed'; end if;
end $$;
rollback;
