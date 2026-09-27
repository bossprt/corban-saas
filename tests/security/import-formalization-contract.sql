-- Contract test for 20260927041919_import_formalization_v1 (ADR-0041): the "Tipo de formalização" of an imported row
-- sets the table's formalization; a row without it leaves the table as it is; any other value is refused. A contract
-- whose seller was already paid can still have its formalization corrected, and nothing else.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/import-formalization-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0401'::uuid as ctype,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.row_of(p_table text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('bank_name', 'Banco Formalizacao', 'agreement_name', 'Convênio F', 'table_name', p_table,
    'contract_type_id', (select ctype from ids), 'contract_type_name', 'Novo (teste)', 'term', 84, 'rate', '1.8',
    'components', jsonb_build_array(jsonb_build_object('component_type_id', (select id from public.commission_component_types where tech_key = 'upfront'),
      'value_kind', 'percentage', 'received_value', '5', 'calculation_base', 'BRUTO', 'source', 'import')),
    'group_values', '[]'::jsonb) || p_extra
$$;
grant execute on function pg_temp.row_of(text, jsonb) to authenticated;
create function pg_temp.form_of(p_table text) returns text language sql as $$
  select formalization from public.product_tables where name = p_table
$$;
grant execute on function pg_temp.form_of(text) to authenticated;
create function pg_temp.case_of(p_id uuid) returns uuid language sql as $$
  select id from public.operational_cases where proposal_id = p_id
$$;
grant execute on function pg_temp.case_of(uuid) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
  pg_temp.row_of('F Fisica', '{"formalization":"physical"}'), pg_temp.row_of('F Digital', '{"formalization":"digital"}'), pg_temp.row_of('F Sem coluna')));
insert into results select 'Físico in the file: physical table', pg_temp.form_of('F Fisica') = 'physical';
insert into results select 'Digital in the file: digital table', pg_temp.form_of('F Digital') = 'digital';
insert into results select 'no column: digital (the default)', pg_temp.form_of('F Sem coluna') = 'digital';
select public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
  pg_temp.row_of('F Fisica', '{"formalization":"digital"}'), pg_temp.row_of('F Digital')));
insert into results select 'imported again as Digital: back to digital', pg_temp.form_of('F Fisica') = 'digital';
insert into results select 'imported again without the column: unchanged', pg_temp.form_of('F Digital') = 'digital';
insert into results select 'any other value is refused',
  pg_temp.err(format('select public.import_smart_commercial_rows(%L, %L, null, null, %L::jsonb)', (select org from ids), 'own',
    jsonb_build_array(pg_temp.row_of('F Estranha', '{"formalization":"hibrido"}')))) = 'invalid_formalization';

-- A contract paid outside Corban: the formalization can still be corrected, nothing else.
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente F', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-F-1', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
select public.move_operational_case(pg_temp.case_of((select id from made where label = 'p')), 'paid', 'Pago ao cliente', null, current_date);
set constraints all immediate; set constraints all deferred;  -- as at commit
select public.register_external_payout((select id from made where label = 'p'), current_date, 'Pago fora do Corban');
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into results select 'paid out: the formalization correction is accepted',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'p'), '{"formalization":"physical"}', 'corrigido')) = 'ok';
insert into results select 'paid out: the formalization was corrected', (select formalization = 'physical' from public.proposals_v2 where id = (select id from made where label = 'p'));
insert into results select 'paid out: the seller keeps what was paid',
  (select paid_on = current_date and credited = 300.00 from public.contract_credit((select id from made where label = 'p')));
insert into results select 'paid out: anything else stays locked',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'p'), '{"formalization":"digital","term":"96"}', 'depois')) = 'contract_payout_received';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'import formalization contract failed'; end if;
end $$;

rollback;
