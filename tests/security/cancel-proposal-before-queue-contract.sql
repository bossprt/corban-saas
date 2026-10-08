-- Contract test for 20261008_cancel_proposal_before_queue_v1: a proposal created from a simulation and not yet in the
-- typing queue can be cancelled by an admin with a reason; the reason is kept as a contract note; the lead goes back to
-- Negotiating; a seller who did not create it is refused; a reason is required; a cancelled proposal cannot be
-- cancelled again; another company is refused. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/cancel-proposal-before-queue-contract.sql

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
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio Cancelar', true from ids returning id \gset agr_
insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco Cancelar', true from ids returning id \gset bank_
insert into made values ('agreement', :'agr_id');
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, :'bank_id', :'agr_id', 'own', 'active' from ids returning id \gset route_
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'cancel-t', 'Tabela Cancelar', 'active', 'digital' from ids returning id \gset tbl_
insert into public.product_table_versions (organization_id, product_table_id, version, status) select org, :'tbl_id', 1, 'draft' from ids returning id \gset ver_
insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, coefficient, tax_pct)
select org, :'ver_id', novo, 84, 84, 84, 0.025, 0 from ids;
select public.publish_product_table_version(:'ver_id', current_date - 1);
insert into made values ('version', :'ver_id');

set local role authenticated;
insert into made select 'lead', public.create_sales_lead((select org from ids), 'Lead Cancelar', '68999660101', '52998224725', null, null);
insert into made select 'client', public.start_lead_sale((select id from made where label = 'lead'), '52998224725');
insert into made select 'sim', public.save_simulation_offer((select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from public.commercial_conditions where product_table_version_id = (select id from made where label = 'version')),
  (select id from made where label = 'agreement'), (select novo from ids), 84, 'amount', 10000);
insert into made select 'proposal', public.create_proposal_from_simulation((select id from made where label = 'sim'));
reset role;
insert into results select 'the lead followed the proposal', (select status = 'proposal' from public.leads where id = (select id from made where label = 'lead'));

select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller who did not create it cannot cancel',
  pg_temp.err(format('select public.cancel_proposal_before_queue(%L, %L)', (select id from made where label = 'proposal'), 'teste')) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'a reason is required',
  pg_temp.err(format('select public.cancel_proposal_before_queue(%L, %L)', (select id from made where label = 'proposal'), ' ')) like '%cancel_reason_required%';
insert into results select 'the admin cancels it',
  pg_temp.err(format('select public.cancel_proposal_before_queue(%L, %L)', (select id from made where label = 'proposal'), 'Era teste')) = 'ok';
insert into results select 'a cancelled proposal cannot be cancelled again',
  pg_temp.err(format('select public.cancel_proposal_before_queue(%L, %L)', (select id from made where label = 'proposal'), 'de novo')) like '%proposal_already_in_queue%';
insert into results select 'unknown proposal (or another company) is refused',
  pg_temp.err(format('select public.cancel_proposal_before_queue(%L, %L)', gen_random_uuid(), 'teste')) like '%not_authorized%';
reset role;

set constraints all immediate;
insert into results select 'the proposal is cancelled, not deleted, with the reason as a note',
  (select status = 'cancelled' from public.proposals_v2 where id = (select id from made where label = 'proposal'))
  and exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'proposal') and kind = 'note' and reason = 'Cancelada antes da fila de digitação: Era teste');
insert into results select 'the lead went back to Negotiating',
  (select status = 'negotiating' and proposal_id is null from public.leads where id = (select id from made where label = 'lead'));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'cancel proposal before queue contract failed'; end if;
end $$;
rollback;
