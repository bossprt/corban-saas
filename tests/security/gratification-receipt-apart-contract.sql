-- Contract test for 20261103155956_gratification_receipt_apart_v1 and 20261103161732_gratification_pending_v1: the Gratificação is received apart from the
-- commission. The à vista receipt expects the commission without the Gratificação; the Gratificação is registered on its
-- own and only then credits the seller's share; contracts credited the old way keep it in the contract credit. Until it is
-- received the contract shows "aguardando Gratificação" (gratification_pending). 20261103164924: a divergent receipt
-- is accepted by the system when the contract is corrected to the amount received.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/gratification-receipt-apart-contract.sql

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
grant insert, select on made to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.pid(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.pid(text) to authenticated;
-- What the active calculation says the company receives (upfront part without the Gratificação, or the Gratificação).
create function pg_temp.expected(p_label text, p_grat boolean) returns text language sql security definer as $$
  select coalesce(sum(l.amount * l.multiplier), 0)::numeric(15,2)::text from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = pg_temp.pid(p_label) and c.status = 'active' and l.line_kind = 'received'
    and case when p_grat then l.component_key = 'gratification' else l.part = 'upfront' and l.component_key <> 'gratification' end
$$;
grant execute on function pg_temp.expected(text, boolean) to authenticated;
create function pg_temp.receive(p_label text, p_kind text, p_amount text) returns text language sql as $$
  select pg_temp.err(format('select public.register_manual_receipt(%L::uuid, %L, %L, current_date, null, %L)', pg_temp.pid(p_label), p_kind, p_amount, 'teste'))
$$;
grant execute on function pg_temp.receive(text, text, text) to authenticated;
create function pg_temp.credit(p_label text, p_source text, p_component text) returns numeric language sql security definer as $$
  select coalesce(sum(e.amount), 0) from public.payout_entries e
  where e.proposal_id = pg_temp.pid(p_label) and e.beneficiary_role = 'originator' and e.status = 'approved' and e.source = p_source
    and (p_component is null or e.component_key = p_component)
$$;
create function pg_temp.payable(p_label text, p_grat boolean) returns numeric language sql security definer as $$
  select coalesce(sum(x.payable), 0) from private.contract_payable(pg_temp.pid(p_label)) x
  where case when p_grat then x.component_key = 'gratification' else x.component_key not in ('deferred', 'gratification') end
$$;

-- Two calculated contracts with a Gratificação of R$ 150,00 typed by hand; the second one is a legacy contract.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Gratificação', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-GRAT-A1', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
insert into made select 'old', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-GRAT-A2', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
insert into made select 'none', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-GRAT-A3', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
select public.set_contract_manual_commission(pg_temp.pid('p'), 'gratification', 'brl', '150.00', 'Gratificação do banco');
select public.set_contract_manual_commission(pg_temp.pid('old'), 'gratification', 'brl', '150.00', 'Gratificação do banco');
-- The test group gives no share of the Gratificação, so the administrator sets R$ 50,00 for the seller on both.
select public.set_payout_override(pg_temp.pid('p'), 'gratification', 'fixed_brl', '50.00', 'parte do vendedor');
select public.set_payout_override(pg_temp.pid('old'), 'gratification', 'fixed_brl', '50.00', 'parte do vendedor');
reset role;
insert into private.gratification_credit_legacy (proposal_id) select pg_temp.pid('old');

insert into results select 'the Gratificação is in force on both contracts', pg_temp.expected('p', true) = '150.00' and pg_temp.expected('old', true) = '150.00';

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'a contract without Gratificação cannot receive one', pg_temp.receive('none', 'gratification', '10.00') like '%manual_receipt_no_calc%';
insert into results select 'à vista paid without the Gratificação is accepted', pg_temp.receive('p', 'upfront', pg_temp.expected('p', false)) = 'ok';
reset role;

insert into results select 'the à vista receipt matches (expected without the Gratificação)',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('p') and x.component_key = 'upfront' and x.reconciliation = 'matched'
          and x.expected_amount = pg_temp.expected('p', false)::numeric);
insert into results select 'the contract credit is released by the à vista receipt', private.contract_bank_receipt(pg_temp.pid('p')) = 'reconciled' and private.contract_credit_released(pg_temp.pid('p'));
insert into results select 'the contract credit leaves the Gratificação out', pg_temp.credit('p', 'contract', null) = pg_temp.payable('p', false);
insert into results select 'nothing of the Gratificação is credited before it is received', pg_temp.credit('p', 'receipt', 'gratification') = 0;
insert into results select 'pending: the contract waits for the Gratificação', private.contract_gratification_pending(pg_temp.pid('p'));
insert into results select 'pending: a contract without Gratificação does not wait', not private.contract_gratification_pending(pg_temp.pid('none'));
insert into results select 'the seller has a share of the Gratificação in this test', pg_temp.payable('p', true) = 50.00;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot register the Gratificação', pg_temp.receive('p', 'gratification', '150.00') ~ 'not_authorized|proposal_not_found';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the Gratificação is registered apart', pg_temp.receive('p', 'gratification', '150.00') = 'ok';
insert into results select 'the Gratificação is received only once', pg_temp.receive('p', 'gratification', '150.00') like '%manual_receipt_duplicate%';
insert into results select 'an invalid kind is refused', pg_temp.receive('p', 'bonus_9', '10.00') like '%invalid_receipt_kind%';
reset role;

insert into results select 'the Gratificação receipt matches the value typed',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('p') and x.component_key = 'gratification' and x.reconciliation = 'matched' and x.amount = 150.00);
insert into results select 'the seller share of the Gratificação is credited when it is received', pg_temp.credit('p', 'receipt', 'gratification') = pg_temp.payable('p', true);
insert into results select 'pending: no longer waits once the Gratificação is received', not private.contract_gratification_pending(pg_temp.pid('p'));
insert into results select 'the contract credit did not change', pg_temp.credit('p', 'contract', null) = pg_temp.payable('p', false);
insert into results select 'the company finance entry names the Gratificação',
  exists (select 1 from public.fin_entries e join public.commission_receipts x on x.id = e.source_ref
          where x.proposal_id = pg_temp.pid('p') and x.component_key = 'gratification' and e.description like 'Gratificação%' and e.amount = 150.00);

-- Legacy: the Gratificação stays inside the contract credit and its receipt credits nothing more.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'legacy: à vista registered', pg_temp.receive('old', 'upfront', pg_temp.expected('old', false)) = 'ok';
insert into results select 'legacy: Gratificação registered', pg_temp.receive('old', 'gratification', '150.00') = 'ok';
reset role;
insert into results select 'legacy: the contract credit keeps the Gratificação', pg_temp.credit('old', 'contract', null) = pg_temp.payable('old', false) + pg_temp.payable('old', true);
insert into results select 'legacy: the Gratificação receipt credits nothing more', pg_temp.credit('old', 'receipt', null) = 0;
insert into results select 'pending: a legacy contract does not wait', not private.contract_gratification_pending(pg_temp.pid('old'));

-- Corrected after the receipt (contract 15178): 6% expected R$ 570,00, R$ 80,00 received, then the Gratificação typed
-- as R$ 75,00 (still divergent) and finally R$ 80,00 (accepted by the system). The acceptance runs at commit, as in
-- the app, so the deferred triggers are fired by "set constraints all immediate" after each change.
set constraints all deferred;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'fix', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-GRAT-A4', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
select public.set_contract_manual_commission(pg_temp.pid('fix'), 'gratification', 'pct_liquido', '6', 'Tac 6%');
select public.set_payout_override(pg_temp.pid('fix'), 'gratification', 'fixed_brl', '20.00', 'parte do vendedor');
set constraints all immediate;
set constraints all deferred;
insert into results select 'fix: à vista registered', pg_temp.receive('fix', 'upfront', pg_temp.expected('fix', false)) = 'ok';
insert into results select 'fix: R$ 80,00 received against 6%', pg_temp.receive('fix', 'gratification', '80.00') = 'ok';
reset role;
insert into results select 'fix: the receipt is divergent and the contract still waits',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('fix') and x.component_key = 'gratification' and x.reconciliation = 'divergent')
  and private.contract_gratification_pending(pg_temp.pid('fix')) and pg_temp.credit('fix', 'receipt', 'gratification') = 0;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_contract_manual_commission(pg_temp.pid('fix'), 'gratification', 'brl', '75.00', 'Correção');
set constraints all immediate;
set constraints all deferred;
reset role;
insert into results select 'fix: corrected to another value, still divergent',
  not exists (select 1 from public.commission_receipt_resolutions z join public.commission_receipts x on x.id = z.receipt_id where x.proposal_id = pg_temp.pid('fix'))
  and private.contract_gratification_pending(pg_temp.pid('fix'));
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_contract_manual_commission(pg_temp.pid('fix'), 'gratification', 'brl', '80.00', 'Correção');
set constraints all immediate;
set constraints all deferred;
reset role;
insert into results select 'fix: corrected to the amount received, accepted by the system with the user who corrected',
  exists (select 1 from public.commission_receipt_resolutions z join public.commission_receipts x on x.id = z.receipt_id
          where x.proposal_id = pg_temp.pid('fix') and x.component_key = 'gratification' and z.note like 'Aceito pelo sistema%' and z.decided_by = (select admin_user from ids));
insert into results select 'fix: the receipt itself is unchanged', exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('fix') and x.component_key = 'gratification' and x.reconciliation = 'divergent' and x.expected_amount = 570.00);
insert into results select 'fix: no longer waits for the Gratificação', not private.contract_gratification_pending(pg_temp.pid('fix'));
insert into results select 'fix: the seller share of the Gratificação is credited', pg_temp.credit('fix', 'receipt', 'gratification') = 20.00;
insert into results select 'fix: the system functions are not callable by users', has_function_privilege('authenticated', 'private.accept_corrected_receipts(uuid)', 'execute') is false;

-- The legacy list is not reachable by users; the finance screens read the pending flag.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'pending: contract_credit returns the flag', (select gratification_pending is false from public.contract_credit(pg_temp.pid('p')));
insert into results select 'pending: contract_payout_totals returns the flag',
  (select bool_and(t.gratification_pending is not null) from public.contract_payout_totals((select org from ids)) t where t.proposal_id in (pg_temp.pid('p'), pg_temp.pid('none')));
insert into results select 'pending: users cannot call the private function', pg_temp.err(format('select private.contract_gratification_pending(%L)', pg_temp.pid('p'))) like '%permission denied%';
insert into results select 'the legacy list is not readable by users', pg_temp.err('select count(*) from private.gratification_credit_legacy') like '%permission denied%';
reset role;

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
  if exists (select 1 from results where not ok or ok is null) then raise exception 'gratification receipt apart contract failed'; end if;
end $$;
rollback;
