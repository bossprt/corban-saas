-- Contract test for 20261009_contract_ade_edit_v1: an admin changes a contract's ADE (history and a new bank identity are
-- kept, the old identity stays); an ADE used by another contract is refused; a malformed ADE is refused; a cancelled
-- contract is refused; another company is refused. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/contract-ade-edit-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user,
       (select id from public.contract_types where tech_key = 'novo' and organization_id is null) as novo;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as((select admin_user from ids));
-- A table with a coefficient (factor) so the simulator offers it.
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio ADE', true from ids returning id \gset agr_
insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco ADE', true from ids returning id \gset bank_
insert into made values ('agreement', :'agr_id');
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, :'bank_id', :'agr_id', 'own', 'active' from ids returning id \gset route_
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'ade-t', 'Tabela ADE', 'active', 'digital' from ids returning id \gset tbl_
insert into public.product_table_versions (organization_id, product_table_id, version, status) select org, :'tbl_id', 1, 'draft' from ids returning id \gset ver_
insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, coefficient, tax_pct)
select org, :'ver_id', novo, 84, 84, 84, 0.025, 0 from ids;
select public.publish_product_table_version(:'ver_id', current_date - 1);
insert into made values ('version', :'ver_id');

set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente ADE', '68999770031', null, 'manual') u;
insert into made select 'sim2', public.save_simulation_offer((select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from public.commercial_conditions where product_table_version_id = (select id from made where label = 'version')),
  (select id from made where label = 'agreement'), (select novo from ids), 84, 'amount', 12000);
insert into made select 'sim', public.save_simulation_offer((select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from public.commercial_conditions where product_table_version_id = (select id from made where label = 'version')),
  (select id from made where label = 'agreement'), (select novo from ids), 84, 'amount', 10000);
insert into made select 'a', public.create_proposal_from_simulation((select id from made where label = 'sim'));
insert into made select 'b', public.create_proposal_from_simulation((select id from made where label = 'sim2'));
reset role;
reset role;

set local role authenticated;
insert into results select 'the admin sets the ADE', pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'a'), 'ADE-77001')) = 'ok';
insert into results select 'changing it again keeps both bank identities',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'a'), 'ADE-77002')) = 'ok';
insert into results select 'an ADE used by another contract is refused',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'b'), 'ADE-77002')) like '%ade_taken%';
insert into results select 'the old number registered for the first contract is refused for another one',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'b'), 'ADE-77001')) like '%ade_taken%';
insert into results select 'a malformed ADE is refused',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'b'), 'ADE 1 2')) like '%invalid_ade%';
insert into results select 'unknown contract (or another company) is refused',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', gen_random_uuid(), 'X1')) like '%not_authorized%';
select public.cancel_proposal_before_queue((select id from made where label = 'b'), 'teste');
insert into results select 'a cancelled contract is refused',
  pg_temp.err(format('select public.set_contract_ade(%L, %L, null)', (select id from made where label = 'b'), 'ADE-77003')) like '%contract_closed%';
reset role;

insert into results select 'the contract has the new ADE and both numbers stay as bank identities',
  (select external_proposal_id = 'ADE-77002' from public.proposals_v2 where id = (select id from made where label = 'a'))
  and (select count(*) = 2 from public.proposal_external_identities where proposal_id = (select id from made where label = 'a') and source = 'ade_edit');
insert into results select 'the history has before -> after',
  exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'a') and kind = 'edit'
          and detail->'external_proposal_id'->>'from' = 'ADE-77001' and detail->'external_proposal_id'->>'to' = 'ADE-77002');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'contract ade edit contract failed'; end if;
end $$;
rollback;
