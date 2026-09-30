-- Contract test for 20260930170805_contract_type_and_origin_ir_v1: the contract type picks the table line (Novo 6-8 and
-- Refinanciamento 6-10 months no longer stop a contract of 8 months), the choice travels from the proposal forms, the portal
-- and the simulation, an edit calculates an uncalculated contract, a recalculation keeps its line, and IR withheld follows
-- the field of the contract's origin (default: the bank's for own production, 0 through a promoter).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/contract-type-origin-ir-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0101'::uuid as own_route,
       '00000000-0000-4000-8000-0000000b0001'::uuid as bank,
       '00000000-0000-4000-8000-0000000a0001'::uuid as agreement,
       '00000000-0000-4000-8000-0000000c0501'::uuid as seed_cond,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from public.contract_types where name = 'Novo' and organization_id is null) as novo,
       (select id from public.contract_types where name = 'Refinanciamento' and organization_id is null) as refin,
       (select id from public.contract_types where name = 'Portabilidade' and organization_id is null) as porta,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
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
-- Contract type of the active calculation's line, or 'none'.
create function pg_temp.calc_type(p_label text) returns text language sql as $$
  select coalesce((select ct.name from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
                   join public.contract_types ct on ct.id = k.contract_type_id where x.proposal_id = pg_temp.id(p_label) and x.status = 'active'), 'none')
$$;
grant execute on function pg_temp.calc_type(text) to authenticated;
create function pg_temp.calc_ir(p_label text) returns numeric language sql as $$
  select ir_withheld_pct from public.proposal_commission_calcs where proposal_id = pg_temp.id(p_label) and status = 'active'
$$;

-- Fixture: a promoter route of the same bank, and on each route (own and promoter) a published table with two lines that
-- overlap at 8 months: Novo 6-8 and Refinanciamento 6-10, commission copied from the seed line.
insert into made values ('provider', gen_random_uuid()), ('promo_route', gen_random_uuid());
insert into public.organization_providers (id, organization_id, name) select pg_temp.id('provider'), org, 'Promotora Contrato' from ids;
insert into public.organization_product_routes (id, organization_id, org_bank_id, org_agreement_id, org_provider_id, production_origin, status)
select pg_temp.id('promo_route'), org, bank, agreement, pg_temp.id('provider'), 'third_party', 'active' from ids;
create function pg_temp.make_table(p_label text, p_route uuid) returns void language plpgsql as $$
declare v_table uuid; v_version uuid; v_cond uuid; x record;
begin
  insert into public.product_tables (organization_id, route_id, code, name) select org, p_route, 'tipo-' || p_label, 'Tabela Tipo ' || p_label from ids returning id into v_table;
  insert into public.product_table_versions (organization_id, product_table_id, version, status) select org, v_table, 1, 'draft' from ids returning id into v_version;
  for x in select * from (values ((select novo from ids), 6, 8), ((select refin from ids), 6, 10)) as t(type_id, tmin, tmax) loop
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, tax_pct)
    select c.organization_id, v_version, x.type_id, x.tmin, x.tmin, x.tmax, c.amount_min, c.amount_max, c.tax_pct from public.commercial_conditions c where c.id = (select seed_cond from ids)
    returning id into v_cond;
    insert into public.commercial_condition_components (organization_id, condition_id, component_type_id, value_kind, received_value, calculation_base, source)
    select organization_id, v_cond, component_type_id, value_kind, received_value, calculation_base, source from public.commercial_condition_components where condition_id = (select seed_cond from ids);
    perform set_config('corban.group_values_conversion', 'on', true);
    insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source)
    select organization_id, v_cond, group_id, component_type_id, value_kind, value, 'manual' from public.commercial_condition_group_values where condition_id = (select seed_cond from ids);
    perform set_config('corban.group_values_conversion', 'off', true);
  end loop;
  update public.product_table_versions set status = 'published', published_at = now(), effective_from = now() - interval '1 day' where id = v_version;
  insert into made values (p_label, v_version);
end $$;
select pg_temp.make_table('tv_own', (select own_route from ids));
select pg_temp.make_table('tv_promo', pg_temp.id('promo_route'));
-- The bank withholds 2% IR on its own production.
update public.organization_banks set ir_withheld_pct = 2 where id = (select bank from ids);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Tipo', '68999770029', null, 'manual') u;
-- Former signature, no type: 8 months fits both lines.
insert into made select 'no_type', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), pg_temp.id('tv_own'), (select seller from ids), 470, 470, 95.88, 8, 'ADE-TIPO-1', 'submitted') d;
-- With the type.
insert into made select 'novo', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), pg_temp.id('tv_own'), (select seller from ids), 470, 470, 95.88, 8, 'ADE-TIPO-2', 'submitted', (select novo from ids)) d;
insert into made select 'promo', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), pg_temp.id('tv_promo'), (select seller from ids), 470, 470, 95.88, 8, 'ADE-TIPO-3', 'submitted', (select refin from ids)) d;
insert into results select 'type the table has not is refused',
  pg_temp.err(format('select public.create_direct_proposal(%L::uuid, %L::uuid, %L::uuid, %L::uuid, 470, 470, 95.88, 8, %L, %L, %L::uuid)',
    (select org from ids), pg_temp.id('client'), pg_temp.id('tv_own'), (select seller from ids), 'ADE-TIPO-4', 'submitted', (select porta from ids))) like '%contract_type_not_in_table%';
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

insert into results select 'without a type: not calculated, ambiguity recorded',
  pg_temp.calc_type('no_type') = 'none'
  and exists (select 1 from public.contract_events where proposal_id = pg_temp.id('no_type') and kind = 'calc_failed' and detail->>'code' = 'condition_ambiguous');
insert into results select 'with Novo: the Novo line', pg_temp.calc_type('novo') = 'Novo';
insert into results select 'type stored on the contract', (select contract_type_id = (select novo from ids) from public.proposals_v2 where id = pg_temp.id('novo'));
insert into results select 'own production: the bank IR (2%)', pg_temp.calc_ir('novo') = 2;
insert into results select 'through a promoter: IR 0 by default', pg_temp.calc_ir('promo') = 0 and pg_temp.calc_type('promo') = 'Refinanciamento';

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
-- Editing the uncalculated contract with its type calculates it.
select public.update_contract(pg_temp.id('no_type'), jsonb_build_object('contract_type_id', (select refin from ids)), null);
insert into results select 'edit with the type calculates it (Refin)', pg_temp.calc_type('no_type') = 'Refinanciamento';
-- A later edit of the amount recalculates on the same line.
select public.update_contract(pg_temp.id('novo'), jsonb_build_object('requested_amount', '480.00'), null);
insert into results select 'recalculation keeps the line', pg_temp.calc_type('novo') = 'Novo'
  and (select count(*) from public.proposal_commission_calcs where proposal_id = pg_temp.id('novo')) >= 2;
insert into results select 'type change is in the history',
  exists (select 1 from public.contract_events where proposal_id = pg_temp.id('no_type') and kind = 'edit' and detail ? 'contract_type_id');
insert into results select 'edit to a type the table has not is refused',
  pg_temp.err(format('select public.update_contract(%L::uuid, %L::jsonb, null)', pg_temp.id('novo'), jsonb_build_object('contract_type_id', (select porta from ids)))) like '%contract_type_not_in_table%';

-- IR per origin: a field the owner fills.
select public.set_origin_ir_withheld((select bank from ids), pg_temp.id('provider'), '1.5');
select public.update_contract(pg_temp.id('promo'), jsonb_build_object('requested_amount', '480.00'), null);
insert into results select 'promoter origin IR set to 1,5% is applied', pg_temp.calc_ir('promo') = 1.5;
select public.set_origin_ir_withheld((select bank from ids), null, '0');
select public.update_contract(pg_temp.id('novo'), jsonb_build_object('requested_amount', '490.00'), null);
insert into results select 'own origin IR set to 0 overrides the bank', pg_temp.calc_ir('novo') = 0;
insert into results select 'invalid IR refused', pg_temp.err(format('select public.set_origin_ir_withheld(%L::uuid, null, %L)', (select bank from ids), '101')) like '%invalid_ir_withheld%';

-- Simulation carries its type into the proposal.
insert into made select 'sim', public.create_simulation_for_condition(pg_temp.id('client'), pg_temp.id('tv_own'), (select refin from ids), 470, 8);
insert into made select 'from_sim', public.create_proposal_from_simulation(pg_temp.id('sim'));
insert into results select 'proposal from simulation keeps the type',
  (select contract_type_id = (select refin from ids) from public.proposals_v2 where id = pg_temp.id('from_sim'));
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot set IR', pg_temp.err(format('select public.set_origin_ir_withheld(%L::uuid, null, %L)', (select bank from ids), '1')) like '%not_authorized%';
reset role;

-- The type changes only through the governed edit.
select set_config('corban.proposal_rpc', 'on', true);
insert into results select 'type cannot change outside the edit',
  pg_temp.err(format('update public.proposals_v2 set contract_type_id = %L where id = %L', (select refin from ids), pg_temp.id('novo'))) like '%proposal_identity_is_immutable%';
select set_config('corban.proposal_rpc', 'off', true);

insert into results select 'anon runs none of them',
  not has_function_privilege('anon', 'public.create_direct_proposal(uuid,uuid,uuid,uuid,numeric,numeric,numeric,integer,text,text,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.set_origin_ir_withheld(uuid,uuid,text)', 'execute')
  and not has_function_privilege('authenticated', 'private.check_contract_type_in_version(uuid,uuid,uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 17 then raise exception 'contract type origin ir contract failed'; end if;
end $$;

rollback;
