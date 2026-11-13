-- Contract test for 20261113202257_bonus_receipt_apart_v1: the Bônus is received apart from the à vista commission
-- (Banco Valor pays at most 6% à vista and the rest in a bonus report). The à vista receipt expects the commission without
-- the Bônus; the Bônus is received on its own (kind "bonus") and only then credits the seller's share (owner, 13/11/2026,
-- option A); contracts already credited the old way keep it in the contract credit.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/bonus-receipt-apart-contract.sql

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
-- What the active calculation says the company receives: à vista (upfront part without Gratificação and Bônus) or the Bônus.
create function pg_temp.expected(p_label text, p_bonus boolean) returns text language sql security definer as $$
  select coalesce(sum(l.amount * l.multiplier), 0)::numeric(15,2)::text from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = pg_temp.pid(p_label) and c.status = 'active' and l.line_kind = 'received'
    and case when p_bonus then l.component_key in ('bonus_1', 'bonus_2', 'bonus_3')
             else l.part = 'upfront' and l.component_key not in ('gratification', 'bonus_1', 'bonus_2', 'bonus_3') end
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
create function pg_temp.payable(p_label text, p_bonus boolean) returns numeric language sql security definer as $$
  select coalesce(sum(x.payable), 0) from private.contract_payable(pg_temp.pid(p_label)) x
  where case when p_bonus then x.component_key in ('bonus_1', 'bonus_2', 'bonus_3')
             else x.component_key not in ('deferred', 'gratification', 'bonus_1', 'bonus_2', 'bonus_3') end
$$;

-- Three contracts; "p" and "old" get a Bônus of R$ 120,00 typed by hand ("old" is a legacy contract), "none" has none.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Bônus', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-BONUS-B1', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
insert into made select 'old', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-BONUS-B2', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
insert into made select 'none', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-BONUS-B3', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
select public.set_contract_manual_commission(pg_temp.pid('p'), 'bonus_1', 'brl', '120.00', 'Bônus da Valor');
select public.set_contract_manual_commission(pg_temp.pid('old'), 'bonus_1', 'brl', '120.00', 'Bônus da Valor');
-- The test group gives no share of the Bônus, so the administrator sets R$ 40,00 for the seller on both.
select public.set_payout_override(pg_temp.pid('p'), 'bonus_1', 'fixed_brl', '40.00', 'parte do vendedor');
select public.set_payout_override(pg_temp.pid('old'), 'bonus_1', 'fixed_brl', '40.00', 'parte do vendedor');
reset role;
insert into private.bonus_credit_legacy (proposal_id) select pg_temp.pid('old');

insert into results select 'the Bônus is in force on both contracts', pg_temp.expected('p', true) = '120.00' and pg_temp.expected('old', true) = '120.00';
insert into results select 'the seller has a share of the Bônus in this test', pg_temp.payable('p', true) = 40.00;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'a contract without Bônus cannot receive one', pg_temp.receive('none', 'bonus', '10.00') like '%manual_receipt_no_calc%';
insert into results select 'à vista paid without the Bônus is accepted', pg_temp.receive('p', 'upfront', pg_temp.expected('p', false)) = 'ok';
reset role;

insert into results select 'the à vista receipt matches (expected without the Bônus)',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('p') and x.component_key = 'upfront' and x.reconciliation = 'matched'
          and x.expected_amount = pg_temp.expected('p', false)::numeric);
insert into results select 'the contract credit is released by the à vista receipt', private.contract_bank_receipt(pg_temp.pid('p')) = 'reconciled' and private.contract_credit_released(pg_temp.pid('p'));
insert into results select 'the contract credit leaves the Bônus out', pg_temp.credit('p', 'contract', null) = pg_temp.payable('p', false);
insert into results select 'nothing of the Bônus is credited before it is received', pg_temp.credit('p', 'receipt', 'bonus') = 0;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot register the Bônus', pg_temp.receive('p', 'bonus', '120.00') ~ 'not_authorized|proposal_not_found';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'file check: the Bônus is not received yet',
  (select result from public.receipt_file_check((select org from ids), 'bank', (select r.org_bank_id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
     join public.organization_product_routes r on r.id = t.route_id where v.id = (select tv from ids)), 'bonus', array['ADE-BONUS-B1'])) = 'ready';
insert into results select 'the Bônus is registered apart', pg_temp.receive('p', 'bonus', '120.00') = 'ok';
insert into results select 'the Bônus is received only once', pg_temp.receive('p', 'bonus', '120.00') like '%manual_receipt_duplicate%';
insert into results select 'an invalid kind is refused', pg_temp.receive('p', 'bonus_1', '10.00') like '%invalid_receipt_kind%';
insert into results select 'file check: the Bônus is reported as received',
  (select result from public.receipt_file_check((select org from ids), 'bank', (select r.org_bank_id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
     join public.organization_product_routes r on r.id = t.route_id where v.id = (select tv from ids)), 'bonus', array['ADE-BONUS-B1'])) = 'received';
reset role;

insert into results select 'the Bônus receipt matches the value in force',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('p') and x.component_key = 'bonus' and x.reconciliation = 'matched' and x.amount = 120.00);
insert into results select 'the seller share of the Bônus is credited when it is received', pg_temp.credit('p', 'receipt', 'bonus') = pg_temp.payable('p', true);
insert into results select 'the contract credit did not change', pg_temp.credit('p', 'contract', null) = pg_temp.payable('p', false);
insert into results select 'the company finance entry names the Bônus',
  exists (select 1 from public.fin_entries e join public.commission_receipts x on x.id = e.source_ref
          where x.proposal_id = pg_temp.pid('p') and x.component_key = 'bonus' and e.description like 'Bônus%' and e.amount = 120.00);

-- Both reports imported together as one à vista (Smart, 28/10/2026): the à vista with the Bônus is accepted, the Bônus
-- share stays in the contract credit and a later Bônus receipt is a duplicate.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'both', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.pid('client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-BONUS-B4', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
select public.set_contract_manual_commission(pg_temp.pid('both'), 'bonus_1', 'brl', '120.00', 'Bônus da Valor');
select public.set_payout_override(pg_temp.pid('both'), 'bonus_1', 'fixed_brl', '40.00', 'parte do vendedor');
insert into results select 'together: à vista with the Bônus is accepted',
  pg_temp.receive('both', 'upfront', (pg_temp.expected('both', false)::numeric + pg_temp.expected('both', true)::numeric)::text) = 'ok';
reset role;
insert into results select 'together: the receipt matches the à vista with the Bônus',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('both') and x.component_key = 'upfront' and x.reconciliation = 'matched'
          and x.expected_amount = pg_temp.expected('both', false)::numeric + pg_temp.expected('both', true)::numeric)
  and private.contract_bonus_in_upfront(pg_temp.pid('both'));
insert into results select 'together: the contract credit keeps the Bônus', pg_temp.credit('both', 'contract', null) = pg_temp.payable('both', false) + pg_temp.payable('both', true);
insert into results select 'separate: the Bônus is not taken as received with the à vista', not private.contract_bonus_in_upfront(pg_temp.pid('p'));
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'together: a later Bônus receipt is a duplicate', pg_temp.receive('both', 'bonus', '120.00') like '%manual_receipt_duplicate%';
insert into results select 'a wrong à vista amount is still divergent (not accepted)',
  pg_temp.receive('none', 'upfront', (pg_temp.expected('none', false)::numeric + 1)::text) = 'ok';
reset role;
insert into results select 'the wrong à vista amount is divergent',
  exists (select 1 from public.commission_receipts x where x.proposal_id = pg_temp.pid('none') and x.component_key = 'upfront' and x.reconciliation = 'divergent');

-- Legacy: the Bônus stays inside the contract credit and its receipt credits nothing more.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'legacy: à vista registered', pg_temp.receive('old', 'upfront', pg_temp.expected('old', false)) = 'ok';
insert into results select 'legacy: Bônus registered', pg_temp.receive('old', 'bonus', '120.00') = 'ok';
reset role;
insert into results select 'legacy: the contract credit keeps the Bônus', pg_temp.credit('old', 'contract', null) = pg_temp.payable('old', false) + pg_temp.payable('old', true);
insert into results select 'legacy: the Bônus receipt credits nothing more', pg_temp.credit('old', 'receipt', null) = 0;

-- The legacy list is not reachable by users.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the legacy list is not readable by users', pg_temp.err('select count(*) from private.bonus_credit_legacy') like '%permission denied%';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'bonus receipt apart contract failed'; end if;
end $$;
rollback;
