-- Contract test for 20260926161438_contract_changes_v1 (part C2, ADR-0039): payout change per commission type (owner
-- or manager, with reason, never above the receipt), edits with history and recalculation (also after paid, owner or
-- manager with reason), notes, what the seller sees, and the lock once the seller received the commission.
-- Local test company: table v2 (6% à vista + 14% diferido on the gross), group Ouro (3% / 7%), seller bound to vendedor@.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/contract-changes-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
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
create function pg_temp.payable(p_component text) returns numeric language sql as $$
  select payable from public.contract_payout((select id from made where label = 'p')) where component_key = p_component
$$;
grant execute on function pg_temp.payable(text) to authenticated;

-- The seller registers the contract (R$ 10.000,00 gross, 120x); the owner calculates it.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente C2', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9000, 250, 120, 'ADE-C2-1', 'submitted') d;
insert into results select 'the seller cannot change the payout',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'percentage', '2', 'capricho')) = 'not_authorized';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'no payout change before the commission is calculated',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'percentage', '2', 'capricho')) = 'commission_not_calculated';
select public.calculate_contract_commission((select id from made where label = 'p'));
insert into results select 'by the rule: 300,00 of the 600,00 à vista', pg_temp.payable('upfront') = 300.00;

-- Owner pays 2% of the base instead (the Fabiola case): 200,00; the rule stays recorded.
select public.set_payout_override((select id from made where label = 'p'), 'upfront', 'percentage', '2', 'empresa lucra mais');
insert into results select 'payout change: 2% of 10.000,00 = 200,00, rule 300,00 kept',
  (select payable = 200.00 and rule_amount = 300.00 and overridden and value_kind = 'percentage' and value = 2 from public.contract_payout((select id from made where label = 'p')) where component_key = 'upfront');
insert into results select 'other types keep the rule', (select payable = rule_amount and not overridden from public.contract_payout((select id from made where label = 'p')) where component_key = 'deferred');
insert into results select 'payout above the receipt refused',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'fixed_brl', '700', 'mais que recebe')) = 'override_exceeds_received';
insert into results select 'a reason is required',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'percentage', '1', 'x')) = 'reason_required';
insert into results select 'a % above 100 refused',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'percentage', '101', 'teste de valor')) = 'invalid_override';
insert into results select 'history is written only through the functions',
  pg_temp.err(format('insert into public.contract_events (organization_id, proposal_id, kind) values (%L, %L, %L)', (select org from ids), (select id from made where label = 'p'), 'note')) <> 'ok';
insert into results select 'a payout change cannot be edited',
  pg_temp.err('update public.contract_payout_overrides set value = 50') <> 'ok' or not exists (select 1 from public.contract_payout_overrides where value = 50);
select public.add_contract_note((select id from made where label = 'p'), 'Cliente pediu retorno amanhã.');
reset role;

-- The seller sees what they will receive (200,00) and the note, never the rule behind the change nor the change itself.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'the seller sees the payable amount',
  (select (x->>'amount')::numeric from jsonb_array_elements(public.proposal_commission_mine((select id from made where label = 'p'))->'payable') x where x->>'component_key' = 'upfront') = 200.00;
insert into results select 'the seller does not see payout changes',
  not exists (select 1 from public.contract_payout_overrides) and not exists (select 1 from public.contract_events where kind like 'payout%');
insert into results select 'the seller sees the note', exists (select 1 from public.contract_events where kind = 'note' and reason = 'Cliente pediu retorno amanhã.');
insert into results select 'the seller cannot read the finance view',
  pg_temp.err(format('select * from public.contract_payout(%L)', (select id from made where label = 'p'))) = 'not_authorized';
-- (flags of earlier calls stay on inside this one test transaction; each API request is its own transaction)
select set_config('corban.proposal_rpc', 'off', true), set_config('corban.proposal_seller_rpc', 'off', true), set_config('corban.paid_evidence_rpc', 'off', true);
insert into results select 'contracts cannot be written directly',
  pg_temp.err(format('update public.proposals_v2 set requested_amount = 1 where id = %L', (select id from made where label = 'p'))) <> 'ok'
  and (select requested_amount = 10000 from public.proposals_v2 where id = (select id from made where label = 'p'));
reset role;

-- Edit: the amount grows; the commission follows and the payout change (2% of the base) follows the new base.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.update_contract((select id from made where label = 'p'), jsonb_build_object('requested_amount', '12000.00'), null);
insert into results select 'edit recalculates: 720,00 received, rule 360,00, change 2% = 240,00',
  (select received = 720.00 and rule_amount = 360.00 and payable = 240.00 from public.contract_payout((select id from made where label = 'p')) where component_key = 'upfront');
insert into results select 'the edit is in the history, before and after',
  exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'p') and kind = 'edit'
            and (detail->'requested_amount'->>'from')::numeric = 10000 and (detail->'requested_amount'->>'to')::numeric = 12000);
insert into results select 'the old calculation stays as history',
  (select count(*) filter (where status = 'superseded') = 1 and count(*) filter (where status = 'active') = 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p'));
insert into results select 'an unknown seller is refused',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, null)', (select id from made where label = 'p'), jsonb_build_object('seller_id', gen_random_uuid()))) = 'seller_not_found';
insert into results select 'a term without a table line is refused',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, null)', (select id from made where label = 'p'), '{"term":"6"}')) = 'condition_not_found';
-- A fixed change of 700,00 fits 720,00; lowering the amount below it is refused as a whole.
select public.set_payout_override((select id from made where label = 'p'), 'upfront', 'fixed_brl', '700', 'bonus combinado');
insert into results select 'an edit that would pay above the receipt is refused',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, null)', (select id from made where label = 'p'), '{"requested_amount":"10000.00"}')) = 'override_exceeds_received'
  and (select requested_amount = 12000 from public.proposals_v2 where id = (select id from made where label = 'p'));
select public.set_payout_override((select id from made where label = 'p'), 'upfront', null, null, 'volta para a regra');
insert into results select 'back to the rule', (select payable = rule_amount and not overridden from public.contract_payout((select id from made where label = 'p')) where component_key = 'upfront');
insert into results select 'every payout change is kept', (select count(*) = 3 from public.contract_payout_overrides where proposal_id = (select id from made where label = 'p'));

-- Paid to the client: still editable and recalculable, by the owner or a manager, with a reason.
select public.move_operational_case((select id from public.operational_cases where proposal_id = (select id from made where label = 'p')), 'paid', 'Pago ao cliente', null);
insert into results select 'paid: a reason is required',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, null)', (select id from made where label = 'p'), '{"term":"96"}')) = 'reason_required';
select public.update_contract((select id from made where label = 'p'), '{"term":"96"}'::jsonb, 'prazo digitado errado');
insert into results select 'paid: edited with a reason', (select term = 96 from public.proposals_v2 where id = (select id from made where label = 'p'));
select public.calculate_contract_commission((select id from made where label = 'p'));
insert into results select 'paid: recalculation allowed', true;
reset role;
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'paid: a supervisor cannot edit',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'p'), '{"term":"84"}', 'tentativa')) = 'not_authorized';
reset role;

-- The seller received this contract's commission (a paid payout holding it): nothing moves any more.
set local session_replication_role = replica;
insert into made select 'payout', gen_random_uuid();
insert into public.payouts (id, organization_id, account_id, kind, amount, status, requested_by)
values ((select id from made where label = 'payout'), (select org from ids), gen_random_uuid(), 'withdrawal', 360, 'paid', (select admin_user from ids));
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, payout_id)
values ((select org from ids), gen_random_uuid(), 'commission', 360, current_date, (select id from made where label = 'p'), gen_random_uuid(), 'originator', 'teste', 'approved', (select id from made where label = 'payout'));
set local session_replication_role = origin;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'received: no edit',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'p'), '{"term":"84"}', 'depois de pago')) = 'contract_payout_received';
insert into results select 'received: no payout change',
  pg_temp.err(format('select public.set_payout_override(%L, %L, %L, %L, %L)', (select id from made where label = 'p'), 'upfront', 'percentage', '1', 'depois de pago')) = 'contract_payout_received';
insert into results select 'received: no recalculation',
  pg_temp.err(format('select public.calculate_contract_commission(%L)', (select id from made where label = 'p'))) = 'contract_payout_received';
insert into results select 'received: the card says it is locked', (select bool_and(locked) from public.contract_payout((select id from made where label = 'p')));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'contract changes contract failed'; end if;
end $$;

rollback;
