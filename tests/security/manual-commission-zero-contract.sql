-- Contract test for 20261110170907_manual_commission_zero_v1: typing 0 zeroes the commission received on one contract
-- (owner 10/11/2026, contract 2756344), "remove" still goes back to the table, old rows with value 0 keep meaning "removed".
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/manual-commission-zero-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select, update on made to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.set(p_component text, p_kind text, p_value text, p_reason text) returns text language sql as $$
  select pg_temp.err(format('select public.set_contract_manual_commission(%L::uuid, %L, %L, %L, %L)', (select id from made where label = 'p'), p_component, p_kind, p_value, p_reason))
$$;
grant execute on function pg_temp.set(text, text, text, text) to authenticated;
create function pg_temp.received(p_component text) returns numeric language sql as $$
  select coalesce(sum(l.amount * l.multiplier), 0) from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = (select id from made where label = 'p') and c.status = 'active' and l.component_key = p_component and l.line_kind = 'received'
$$;
grant execute on function pg_temp.received(text) to authenticated;
-- Contratos reads "calculated" from the active calculation's lines: a zeroed component must still write them (at R$ 0).
create function pg_temp.lines(p_component text) returns bigint language sql as $$
  select count(*) from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = (select id from made where label = 'p') and c.status = 'active' and l.component_key = p_component and l.line_kind = 'received'
$$;
grant execute on function pg_temp.lines(text) to authenticated;

-- A calculated contract: gross 10.000,00, net 9.500,00.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '11144477735', 'Cliente Zerar', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-ZERO-1', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
reset role;
create temp table before as select pg_temp.received('upfront') upfront;
grant select on before to authenticated;
insert into results select 'the contract is calculated from the table', (select upfront > 0 from before) and pg_temp.received('gratification') = 0;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'zeroing is refused while the seller would get more than the company receives', pg_temp.set('upfront', 'brl', '0', 'Banco não paga este contrato') like '%exceeds_received%';
reset role;
-- Test setup only (rolled back): the seller's group pays nothing, as for contract 2756344 (seller rule R$ 0).
set local session_replication_role = replica;
update public.commission_group_rule_items i set distributed_pct = 0
from public.commission_group_rules r where r.id = i.rule_id and r.group_id = (select commission_group_id from public.commercial_sellers where id = (select seller from ids));
set local session_replication_role = origin;
set local role authenticated;
insert into made select 'p0', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-ZERO-2', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
-- From here on, the contract whose seller gets R$ 0, as contract 2756344.
update made set label = 'p_seller' where label = 'p';
update made set label = 'p' where label = 'p0';
create temp table before0 as select pg_temp.received('upfront') upfront;
insert into results select 'the contract with the seller at R$ 0 is calculated too', (select upfront > 0 from before0);
insert into results select 'R$ 0 zeroes a component the table pays', pg_temp.set('upfront', 'brl', '0', 'Banco não paga este contrato') = 'ok' and pg_temp.received('upfront') = 0;
insert into results select 'the zeroed contract still counts as calculated (its lines are written at R$ 0)', pg_temp.lines('upfront') > 0;
insert into results select '0% also zeroes it', pg_temp.set('upfront', 'pct_liquido', '0', 'Zerar de novo') = 'ok' and pg_temp.received('upfront') = 0;
insert into results select 'remove goes back to the table', pg_temp.set('upfront', 'remove', null, 'Banco voltou a pagar') = 'ok' and pg_temp.received('upfront') = (select upfront from before0);
insert into results select 'a component outside the table can be zeroed (line at R$ 0)', pg_temp.set('gratification', 'brl', '0', 'Sem gratificação') = 'ok' and pg_temp.received('gratification') = 0 and pg_temp.lines('gratification') > 0;
insert into results select 'a negative value is refused', pg_temp.set('upfront', 'brl', '-1', 'erro') like '%invalid_amount%';
reset role;

insert into results select 'the seller gets R$ 0 on that contract', (select coalesce(sum(payable), 0) = 0 from private.contract_payable((select id from made where label = 'p')));
insert into results select 'the zeroed rows are R$ 0 with the marker; the removal is not marked',
  (select count(*) = 3 from public.proposal_manual_components where proposal_id = (select id from made where label = 'p') and zeroed and value = 0 and value_kind = 'fixed_brl' and base is null)
  and (select count(*) = 1 from public.proposal_manual_components where proposal_id = (select id from made where label = 'p') and not zeroed);
insert into results select 'the history says "zero"',
  (select count(*) = 3 from public.contract_events where proposal_id = (select id from made where label = 'p') and kind = 'manual_commission' and detail->>'kind' = 'zero');
-- Past the RPC gate on purpose, to reach the table rule itself.
-- 20261110230000: once paid, a contract whose company receives R$ 0 does not wait for the bank; one that receives does.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the contract can be zeroed again (upfront and deferred)', pg_temp.set('upfront', 'brl', '0', 'Banco não paga este contrato') = 'ok' and pg_temp.set('deferred', 'brl', '0', 'Banco não paga este contrato') = 'ok' and pg_temp.received('upfront') = 0 and pg_temp.received('deferred') = 0;
reset role;
set local session_replication_role = replica; -- test-only setup: mark both contracts paid to the client
update public.proposals_v2 set status = 'paid', physical_received_at = coalesce(physical_received_at, now())
where id in (select id from made where label in ('p', 'p_seller'));
set local session_replication_role = origin;
insert into results select 'a paid contract receiving R$ 0 does not wait for the bank (concluded, no payout)',
  (select waiting from private.contract_credit_state((select id from made where label = 'p'))) = 'no_payout';
insert into results select 'a paid contract that receives something still waits for the bank',
  (select waiting from private.contract_credit_state((select id from made where label = 'p_seller'))) = 'bank';

select set_config('corban.manual_commission_rpc', 'on', true);
insert into results select 'a zeroed row must be R$ 0',
  pg_temp.err(format('insert into public.proposal_manual_components (organization_id, proposal_id, component_type_id, value_kind, base, value, zeroed, reason) select %L, %L, id, %L, null, 5, true, %L from public.commission_component_types where tech_key = %L',
    (select org from ids), (select id from made where label = 'p'), 'fixed_brl', 'erro', 'upfront')) like '%proposal_manual_components_zeroed%';
select set_config('corban.manual_commission_rpc', 'off', true);

-- 20261111000000: contract_payout_totals computes the state inline and must agree with contract_credit_state.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
create temp table pt_check as select t.proposal_id, t.waiting, t.credited, t.paid_on from public.contract_payout_totals((select org from ids)) t;
reset role;
insert into results select 'payout totals: same state as contract_credit_state for every contract',
  (select count(*) > 0 from pt_check) and not exists (select 1 from pt_check t cross join lateral private.contract_credit_state(t.proposal_id) s
    where row(t.waiting, t.credited, t.paid_on) is distinct from row(s.waiting, s.credited, s.paid_on));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'manual commission zero contract failed'; end if;
end $$;
rollback;
