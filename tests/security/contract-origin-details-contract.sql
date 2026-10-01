-- Contract test for 20261001172732_contract_origin_details_v1: saldo devedor, banco and nº do contrato de origem are
-- recorded on creation (direct proposal and broker portal) and on edit with history, never recalculate the commission,
-- and refuse malformed values. The former calls (no details) keep working. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/contract-origin-details-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select contract_type_id from public.commercial_conditions where product_table_version_id = '00000000-0000-4000-8000-0000000c0302' limit 1) as ctype,
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
create function pg_temp.id(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.id(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Origem', '68999770039', null, 'manual') u;
insert into made select 'with', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids),
  10000, 1500, 250, 120, 'ADE-ORIG-1', 'submitted', (select ctype from ids),
  jsonb_build_object('outstanding_balance', '8500.00', 'origin_bank_name', 'Banco do Brasil', 'origin_contract_number', 'BB-123/45')) d;
insert into made select 'former', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids),
  10000, 9500, 250, 120, 'ADE-ORIG-2', 'submitted') d;
insert into made select 'typed', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids),
  10000, 9500, 250, 120, 'ADE-ORIG-3', 'submitted', (select ctype from ids)) d;
insert into results select 'malformed balance refused',
  pg_temp.err(format('select public.create_direct_proposal(%L::uuid, %L::uuid, %L::uuid, %L::uuid, 10000, 9500, 250, 120, %L, %L, %L::uuid, %L::jsonb)',
    (select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 'ADE-ORIG-4', 'submitted', (select ctype from ids),
    jsonb_build_object('outstanding_balance', '8.500,00'))) like '%invalid_outstanding_balance%';
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

insert into results select 'details recorded on creation',
  (select outstanding_balance = 8500.00 and origin_bank_name = 'Banco do Brasil' and origin_contract_number = 'BB-123/45' from public.proposals_v2 where id = pg_temp.id('with'));
insert into results select 'former call without details still works',
  (select outstanding_balance is null and origin_bank_name is null from public.proposals_v2 where id = pg_temp.id('former'))
  and (select outstanding_balance is null from public.proposals_v2 where id = pg_temp.id('typed'));

create temp table calc_before as select id from public.proposal_commission_calcs where proposal_id = pg_temp.id('with') and status = 'active';
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.update_contract(pg_temp.id('with'), jsonb_build_object('outstanding_balance', '8700.50', 'origin_contract_number', ''), null);
insert into results select 'edit changes the balance and clears the number',
  (select outstanding_balance = 8700.50 and origin_bank_name = 'Banco do Brasil' and origin_contract_number is null from public.proposals_v2 where id = pg_temp.id('with'));
insert into results select 'edit in the history',
  exists (select 1 from public.contract_events where proposal_id = pg_temp.id('with') and kind = 'edit' and detail ? 'outstanding_balance' and detail ? 'origin_contract_number');
insert into results select 'malformed balance refused on edit',
  pg_temp.err(format('select public.update_contract(%L::uuid, %L::jsonb, null)', pg_temp.id('with'), jsonb_build_object('outstanding_balance', '-5'))) like '%invalid_outstanding_balance%';
insert into results select 'too long origin bank refused',
  pg_temp.err(format('select public.update_contract(%L::uuid, %L::jsonb, null)', pg_temp.id('with'), jsonb_build_object('origin_bank_name', repeat('x', 121)))) like '%invalid_origin_bank%';
reset role;
insert into results select 'origin data never recalculates the commission',
  (select id from public.proposal_commission_calcs where proposal_id = pg_temp.id('with') and status = 'active') = (select id from calc_before);

insert into results select 'anon runs none of them',
  not has_function_privilege('anon', 'public.create_direct_proposal(uuid,uuid,uuid,uuid,numeric,numeric,numeric,integer,text,text,uuid,jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.submit_broker_proposal(uuid,text,text,text,text,uuid,numeric,numeric,numeric,integer,text,uuid,jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'private.contract_origin_details(jsonb)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 9 then raise exception 'contract origin details contract failed'; end if;
end $$;

rollback;
