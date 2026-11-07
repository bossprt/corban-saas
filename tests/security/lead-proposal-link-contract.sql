-- Contract test for 20261107044031_lead_proposal_link_v1: "Venda fechada" from a lead (close_lead_sale) creates the
-- proposal with the lead's seller (or the closing user's, or the one chosen in the dialog; none -> seller_required), links
-- it to that lead (origin_lead_id, immutable) and the lead follows that proposal only. Proposals without an origin lead
-- keep following the client as before. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/lead-proposal-link-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
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
create function pg_temp.id(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.id(text) to authenticated;

-- Fixtures: a table with a factor, a seller for the first seller user, and none for the administrator.
select pg_temp.act_as((select admin_user from ids));
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio Venda Lead', true from ids returning id \gset agr_
insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco Venda Lead', true from ids returning id \gset bank_
insert into made values ('agreement', :'agr_id');
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, :'bank_id', :'agr_id', 'own', 'active' from ids returning id \gset route_
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'lead-link-t', 'Tabela Venda Lead', 'active', 'digital' from ids returning id \gset tbl_
insert into public.product_table_versions (organization_id, product_table_id, version, status) select org, :'tbl_id', 1, 'draft' from ids returning id \gset ver_
insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, coefficient, tax_pct)
select org, :'ver_id', novo, 84, 84, 84, 0.025, 0 from ids;
select public.publish_product_table_version(:'ver_id', current_date - 1);
insert into made values ('version', :'ver_id');
update public.commercial_sellers set user_id = null where organization_id = (select org from ids) and user_id in ((select admin_user from ids), (select v1 from ids));
insert into public.commercial_sellers (organization_id, name, seller_category, commission_group_id, is_active, user_id)
select org, 'Vendedor Lead Link', 'pf', (select id from public.commission_groups where organization_id = org order by sort_order limit 1), true, v1 from ids returning id \gset s1_
insert into made values ('seller1', :'s1_id');
insert into public.commercial_sellers (organization_id, name, seller_category, commission_group_id, is_active)
select org, 'Vendedor Escolhido', 'pf', (select id from public.commission_groups where organization_id = org order by sort_order limit 1), true from ids returning id \gset s2_
insert into made values ('seller2', :'s2_id');

create function pg_temp.offer(p_client uuid) returns uuid language sql as $$
  select public.save_simulation_offer(p_client, pg_temp.id('version'),
    (select id from public.commercial_conditions where product_table_version_id = pg_temp.id('version')),
    pg_temp.id('agreement'), (select novo from ids), 84, 'amount', 10000)
$$;
grant execute on function pg_temp.offer(uuid) to authenticated;

set local role authenticated;
-- Lead A (owned by seller 1), its client, two offers; lead B of the same client (an older sales effort).
insert into made select 'leadA', public.create_sales_lead((select org from ids), 'Lead Venda A', '68999770101', '73184620590', null, null);
insert into made select 'client', public.start_lead_sale(pg_temp.id('leadA'), '73184620590');
insert into made select 'simA1', pg_temp.offer(pg_temp.id('client'));
insert into made select 'simA2', pg_temp.offer(pg_temp.id('client'));
-- Lead C (no seller anywhere) with another client.
insert into made select 'leadC', public.create_sales_lead((select org from ids), 'Lead Venda C', '68999770103', '73184620670', null, null);
insert into made select 'clientC', public.start_lead_sale(pg_temp.id('leadC'), '73184620670');
insert into made select 'simC', pg_temp.offer(pg_temp.id('clientC'));
reset role;
update public.leads set owner_user_id = (select v1 from ids) where id = pg_temp.id('leadA');
update public.leads set owner_user_id = null where id = pg_temp.id('leadC');
-- Lead B: same client, open, owned by nobody (inserted directly: a second sales effort for the client).
insert into public.leads (organization_id, status, channel, full_name, customer_id, converted_at, created_by)
select org, 'negotiating', 'manual', 'Lead Venda B', pg_temp.id('client'), now(), admin_user from ids returning id \gset lb_
insert into made values ('leadB', :'lb_id');

-- 1. No seller for the lead's owner nor for the closing administrator: refused, the screen asks.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'no seller anywhere: seller_required',
  pg_temp.err(format('select public.close_lead_sale(%L, %L)', pg_temp.id('leadC'), pg_temp.id('simC'))) like '%seller_required%';
insert into results select 'nothing was created on refusal',
  not exists (select 1 from public.proposals_v2 where simulation_id = pg_temp.id('simC'));
insert into results select 'an inactive or unknown seller is refused',
  pg_temp.err(format('select public.close_lead_sale(%L, %L, %L)', pg_temp.id('leadC'), pg_temp.id('simC'), gen_random_uuid())) like '%seller_not_found%';
insert into results select 'a simulation of another client is refused',
  pg_temp.err(format('select public.close_lead_sale(%L, %L)', pg_temp.id('leadA'), pg_temp.id('simC'))) like '%simulation_not_of_lead_client%';

-- 2. The seller chosen in the dialog is used.
insert into made select 'pC', public.close_lead_sale(pg_temp.id('leadC'), pg_temp.id('simC'), pg_temp.id('seller2'));
insert into results select 'chosen seller goes on the proposal', (select seller_id = pg_temp.id('seller2') and origin_lead_id = pg_temp.id('leadC') from public.proposals_v2 where id = pg_temp.id('pC'));

-- 3. Lead A: the administrator closes; the seller comes from the lead's owner; only lead A follows the proposal.
insert into made select 'pA1', public.close_lead_sale(pg_temp.id('leadA'), pg_temp.id('simA1'));
reset role;
insert into results select 'lead owner seller goes on the proposal', (select seller_id = pg_temp.id('seller1') from public.proposals_v2 where id = pg_temp.id('pA1'));
insert into results select 'proposal remembers its lead', (select origin_lead_id = pg_temp.id('leadA') and status = 'draft' from public.proposals_v2 where id = pg_temp.id('pA1'));
insert into results select 'the lead follows its own proposal', (select status = 'proposal' and proposal_id = pg_temp.id('pA1') from public.leads where id = pg_temp.id('leadA'));
insert into results select 'another open lead of the same client is not taken', (select status = 'negotiating' and proposal_id is null from public.leads where id = pg_temp.id('leadB'));
insert into results select 'the simulation is used up', (select status = 'selected' from public.simulations where id = pg_temp.id('simA1'));
insert into results select 'proposal_linked event recorded for the lead',
  exists (select 1 from public.lead_events where lead_id = pg_temp.id('leadA') and event_type = 'proposal_linked' and detail->>'proposal_id' = pg_temp.id('pA1')::text);

-- 4. The origin lead never changes.
insert into results select 'origin lead is immutable',
  pg_temp.err(format('update public.proposals_v2 set origin_lead_id = %L where id = %L', pg_temp.id('leadB'), pg_temp.id('pA1'))) like '%proposal_origin_lead_is_immutable%';

-- 5. Old behaviour for proposals without an origin lead: open leads of the client follow it; lead A (in proposal) does not move.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'pOld', public.create_proposal_from_simulation(pg_temp.id('simA2'));
reset role;
insert into results select 'proposal without origin lead: open lead of the client follows (old behaviour)',
  (select status = 'proposal' and proposal_id = pg_temp.id('pOld') from public.leads where id = pg_temp.id('leadB'));
insert into results select 'proposal without origin lead has no seller and no lead (unchanged)',
  (select seller_id is null and origin_lead_id is null from public.proposals_v2 where id = pg_temp.id('pOld'));
insert into results select 'lead A still follows its own proposal', (select proposal_id = pg_temp.id('pA1') from public.leads where id = pg_temp.id('leadA'));

-- 6. Cancelling the other proposal does not touch lead A; cancelling lead A's proposal brings it back to negotiating.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.cancel_proposal_before_queue(pg_temp.id('pOld'), 'teste de contrato');
reset role;
insert into results select 'cancelling another proposal of the client leaves lead A in proposal',
  (select status = 'proposal' and proposal_id = pg_temp.id('pA1') from public.leads where id = pg_temp.id('leadA'));
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.cancel_proposal_before_queue(pg_temp.id('pA1'), 'teste de contrato');
reset role;
insert into results select 'cancelling its own proposal brings lead A back to negotiating',
  (select status = 'negotiating' and proposal_id is null from public.leads where id = pg_temp.id('leadA'));

-- 7. A seller cannot close a lead outside their scope; the second seller sees nothing of lead A.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'a seller cannot close a lead of someone else',
  pg_temp.err(format('select public.close_lead_sale(%L, %L)', pg_temp.id('leadA'), pg_temp.id('simA2'))) ~ '(lead_not_found|not_authorized|simulation_not)';
reset role;

-- 8. The function is not open to anonymous callers.
insert into results select 'anon cannot execute close_lead_sale', not has_function_privilege('anon', 'public.close_lead_sale(uuid,uuid,uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'lead-proposal-link contract failed: %', (select string_agg(check_name, '; ') from results where not ok); end if;
  if (select count(*) from results) < 19 then raise exception 'lead-proposal-link contract: missing checks'; end if;
end $$;

rollback;
