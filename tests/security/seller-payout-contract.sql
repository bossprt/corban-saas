-- Contract test for 20260924190449_seller_payout_v1: credits from reconciled receipts with the frozen split, seller
-- without login paid on the seller account, divergent receipts only after acceptance, proportional chargeback never
-- beyond what was received, manual entries with two eyes and installments, closing with the 30% debt limit,
-- withdrawal up to the available balance, model switch without paying twice, visibility and immutability.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/seller-payout-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- Entries of an account as 'kind:amount' in creation order.
create function pg_temp.entries(p_account uuid) returns text language sql as $$
  select string_agg(kind || ':' || amount::text, ' ' order by created_at, amount desc) from public.payout_entries where account_id = p_account and status = 'approved'
$$;
create function pg_temp.balance(p_account uuid) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.payout_entries where account_id = p_account and status = 'approved'
$$;
create function pg_temp.receive(p_label text, p_kind text, p_rows jsonb) returns uuid language plpgsql as $$
declare v uuid;
begin
  v := public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), p_kind, current_date,
         p_label || '.csv', encode(sha256(convert_to(p_label || clock_timestamp()::text, 'utf8')), 'hex'), null, p_rows);
  insert into made values (p_label, v);
  return v;
end $$;
grant execute on function pg_temp.entries(uuid), pg_temp.balance(uuid), pg_temp.receive(text, text, jsonb) to authenticated;

insert into made select 'bank', r.org_bank_id
from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id join public.organization_product_routes r on r.id = t.route_id
where v.id = (select tv from ids);
-- vendedor2 becomes the finance person (second pair of eyes).
update public.organization_memberships set role_id = (select id from public.organization_roles where organization_id = (select org from ids) and key = 'financeiro')
where organization_id = (select org from ids) and user_id = (select v2 from ids);

-- Hierarchy (supervisor leads vendedor; admin leads supervisor), owner rule, three proposals of the example.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select sup_user from ids)), null, (select admin_user from ids), null);
select public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 10, 15, 75, true, 'regra do exemplo');
select public.save_payout_settings((select org from ids), 'closing', 'monthly', 30);
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Repasse', '68999770009', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-PAY-1', 'submitted') d;
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-PAY-2', 'submitted') d;
insert into made select 'p3', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-PAY-3', 'submitted') d;
select public.calculate_proposal_commission((select id from made where label = 'p1'));
select public.calculate_proposal_commission((select id from made where label = 'p2'));
select public.calculate_proposal_commission((select id from made where label = 'p3'));
insert into made select 'acc_seller', id from public.payout_accounts where seller_id = (select seller from ids);
reset role;

-- Upfront report: p1 exact, p2 one cent short (divergent), p3 exact. Confirmed by finance.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
select pg_temp.receive('up', 'upfront', jsonb_build_array(
  jsonb_build_object('row', 1, 'ade', 'ADE-PAY-1', 'amount', '600.00'),
  jsonb_build_object('row', 2, 'ade', 'ADE-PAY-2', 'amount', '599.99'),
  jsonb_build_object('row', 3, 'ade', 'ADE-PAY-3', 'amount', '600.00')));
select public.confirm_receipt_report((select id from made where label = 'up'));
insert into made select 'acc_seller', a.id from public.payout_accounts a where a.seller_id = (select seller from ids) and not exists (select 1 from made where label = 'acc_seller');
insert into made select 'acc_sup', a.id from public.payout_accounts a where a.user_id = (select sup_user from ids);
insert into made select 'acc_mgr', a.id from public.payout_accounts a where a.user_id = (select admin_user from ids);
insert into results select 'seller account credited with the approved example (253,80)',
  (select sum(amount) from public.payout_entries where account_id = (select id from made where label = 'acc_seller') and proposal_id = (select id from made where label = 'p1')) = 253.80;
insert into results select 'supervisor and manager credited from the frozen hierarchy (50,76 / 33,84)',
  (select sum(amount) from public.payout_entries where account_id = (select id from made where label = 'acc_sup') and proposal_id = (select id from made where label = 'p1')) = 50.76
  and (select sum(amount) from public.payout_entries where account_id = (select id from made where label = 'acc_mgr') and proposal_id = (select id from made where label = 'p1')) = 33.84;
insert into results select 'divergent receipt credits nobody before acceptance',
  not exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'p2'));
select public.accept_receipt_divergence(x.id, 'banco pagou um centavo a menos')
from public.commission_receipts x where x.proposal_id = (select id from made where label = 'p2');
insert into results select 'accepted divergence splits what actually arrived (599,99 -> 253,79)',
  (select sum(amount) from public.payout_entries where account_id = (select id from made where label = 'acc_seller') and proposal_id = (select id from made where label = 'p2')) = 253.79;

-- Deferred installment 1 of p1 (the rule pays the deferred to the team).
select pg_temp.receive('dif', 'deferred', jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'ADE-PAY-1', 'amount', '11.67')));
select public.confirm_receipt_report((select id from made where label = 'dif'));
insert into results select 'deferred installment split 4,94 / 0,99 / 0,66',
  (select string_agg(e.amount::text, '/' order by e.amount desc) from public.payout_entries e join public.commission_receipts x on x.id = e.receipt_id
   where x.report_id = (select id from made where label = 'dif')) = '4.94/0.99/0.66';

-- Chargebacks on p3: half, then more than what is left (divergent, accepted): never beyond what was received.
select pg_temp.receive('cb1', 'chargeback', jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'ADE-PAY-3', 'amount', '300.00')));
select public.confirm_receipt_report((select id from made where label = 'cb1'));
insert into results select 'half chargeback: -126,90 / -25,38 / -16,92',
  (select string_agg(e.amount::text, '/' order by e.amount) from public.payout_entries e join public.commission_receipts x on x.id = e.receipt_id
   where x.report_id = (select id from made where label = 'cb1')) = '-126.90/-25.38/-16.92';
select pg_temp.receive('cb2', 'chargeback', jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'ADE-PAY-3', 'amount', '400.00')));
select public.confirm_receipt_report((select id from made where label = 'cb2'));
select public.accept_receipt_divergence(x.id, 'estorno acima do recebido, conferido com o banco')
from public.commission_receipts x where x.report_id = (select id from made where label = 'cb2');
insert into results select 'chargeback beyond the received amount stops at zero per person',
  not exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'p3')
              group by account_id having sum(amount) <> 0);
reset role;
do $$ declare n int := (select count(*) from public.payout_entries); r record;
begin
  for r in select id from public.commission_receipts where report_id in (select id from made) loop perform private.post_receipt(r.id); end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  insert into results values ('posting is idempotent', (select count(*) from public.payout_entries) = n);
end $$;

-- Manual entries: admin enters, cannot approve; the account holder cannot approve either; finance approves.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'adv', public.add_payout_entry((select id from made where label = 'acc_seller'), 'advance', 600, null, 'Vale de setembro', current_date, 3);
insert into made select 'adj', public.add_payout_entry((select id from made where label = 'acc_sup'), 'adjustment', 100, 'debit', 'Multa de atraso', current_date - 60, 1);
insert into results select 'advance in 3 monthly installments of -200,00, pending',
  (select string_agg(amount::text || '@' || (effective_on - current_date >= 0)::text || '/' || status, ' ' order by effective_on) from public.payout_entries where entry_group = (select id from made where label = 'adv'))
  = '-200.00@true/pending -200.00@true/pending -200.00@true/pending';
do $$ begin
  begin
    perform public.decide_payout_entry((select id from public.payout_entries where entry_group = (select id from made where label = 'adv') limit 1), true, null);
    insert into results values ('who entered cannot approve', false);
  exception when others then insert into results values ('who entered cannot approve', sqlerrm = 'four_eyes_required'); end;
end $$;
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
select public.decide_payout_entry((select id from public.payout_entries where entry_group = (select id from made where label = 'adv') limit 1), true, null);
select public.decide_payout_entry((select id from public.payout_entries where entry_group = (select id from made where label = 'adj') limit 1), true, null);
insert into results select 'approving one installment approves the whole advance',
  not exists (select 1 from public.payout_entries where entry_group = (select id from made where label = 'adv') and status <> 'approved');
do $$ begin
  begin
    update public.payout_entries set amount = -1 where entry_group = (select id from made where label = 'adv');
    insert into results values ('entries cannot be edited directly', false);
  exception when others then insert into results values ('entries cannot be edited directly', true); end;
end $$;

-- Closing with the 30% limit on the supervisor account: first period only the -100 debt, then the credits.
select public.close_payout_period((select org from ids), current_date - 30);
insert into results select 'first closing carries the debt (nothing to pay)',
  (select amount = 0 and status = 'settled' and carry_out = -100 from public.payouts where account_id = (select id from made where label = 'acc_sup'));
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.close_payout_period((select org from ids), current_date);
insert into made select 'st_sup', id from public.payouts where account_id = (select id from made where label = 'acc_sup') and status = 'pending';
-- Supervisor net 102,51 (50,76 + 0,99 + 50,76 + 50,76 - 25,38 - 25,38): deduction trunc(30%) = 30,75, pays 71,76, carries -69,25.
insert into results select 'closing deducts at most 30% of the net: 102,51 -> pays 71,76, carries -69,25',
  (select period_net = 102.51 and debt_deduction = 30.75 and amount = 71.76 and carry_out = -69.25 from public.payouts where id = (select id from made where label = 'st_sup'));
insert into results select 'a second closing does not duplicate an unpaid statement', public.close_payout_period((select org from ids), current_date) = 0;
do $$ begin
  begin
    perform public.decide_payout((select id from made where label = 'st_sup'), true, null);
    insert into results values ('who closed cannot approve the statement', false);
  exception when others then insert into results values ('who closed cannot approve the statement', sqlerrm = 'four_eyes_required'); end;
end $$;
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
select public.decide_payout((select id from made where label = 'st_sup'), true, null);
select public.mark_payout_paid((select id from made where label = 'st_sup'), current_date, 'PIX 123456');
insert into results select 'after payment the ledger balance equals the carry', pg_temp.balance((select id from made where label = 'acc_sup')) = -69.25;
reset role;

-- The seller moves to the account model and withdraws up to the available balance.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.decide_payout(id, false, 'seller moves to account model') from public.payouts where account_id = (select id from made where label = 'acc_seller') and status = 'pending';
select public.set_payout_account_model((select id from made where label = 'acc_seller'), 'account');
reset role;
-- Seller balance available today: 253,80 + 253,79 + 4,94 + 253,80 - 126,90 - 126,90 - 200,00 (first advance installment) = 312,53.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
do $$ begin
  begin
    perform public.request_payout_withdrawal((select id from made where label = 'acc_seller'), 312.54, null);
    insert into results values ('withdrawal limited to the available balance', false);
  exception when others then insert into results values ('withdrawal limited to the available balance', sqlerrm = 'insufficient_balance'); end;
end $$;
insert into made select 'wd', public.request_payout_withdrawal((select id from made where label = 'acc_seller'), 312.53, 'saque do mês');
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.decide_payout((select id from made where label = 'wd'), true, null);
select public.mark_payout_paid((select id from made where label = 'wd'), current_date, 'PIX 654321');
-- Back to closings: an opening statement settles the history, so the next closing picks only the future installments.
select public.set_payout_account_model((select id from made where label = 'acc_seller'), 'closing');
insert into results select 'switching to closing opens with the current balance and pays nothing twice',
  (select carry_out = 0 and status = 'settled' from public.payouts where account_id = (select id from made where label = 'acc_seller') and note like 'Saldo de abertura%')
  and not exists (select 1 from public.payout_entries where account_id = (select id from made where label = 'acc_seller') and statement_id is null and effective_on <= current_date and status = 'approved' and kind <> 'payout');
reset role;

-- A seller without login: still paid on the seller account; no hierarchy, so no supervisor or manager share
-- (and never the hierarchy of whoever typed the proposal).
update public.commercial_sellers set user_id = null where id = (select seller from ids);
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'p4', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-PAY-4', 'submitted') d;
select public.calculate_proposal_commission((select id from made where label = 'p4'));
insert into results select 'seller without login: originator is the seller, no inherited hierarchy',
  (select originator_user_id is null and supervisor_user_id is null and manager_user_id is null and seller_id = (select seller from ids)
   from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p4') and status = 'active');
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
select pg_temp.receive('up4', 'upfront', jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'ADE-PAY-4', 'amount', '600.00')));
select public.confirm_receipt_report((select id from made where label = 'up4'));
insert into results select 'seller without login credited 253,80 and nobody else',
  (select string_agg(account_id::text || '=' || amount::text, ',') from public.payout_entries where proposal_id = (select id from made where label = 'p4'))
  = (select id from made where label = 'acc_seller')::text || '=253.80';
reset role;
update public.commercial_sellers set user_id = (select v1 from ids) where id = (select seller from ids);

-- Visibility: the member without finance access sees only their own account; anon has no grants.
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'a person sees only their own account and entries',
  (select count(*) from public.payout_accounts) = 1 and not exists (select 1 from public.payout_entries where account_id <> (select id from made where label = 'acc_sup'));
do $$ begin
  begin
    perform public.close_payout_period((select org from ids), current_date);
    insert into results values ('without repasse permission nobody closes a period', false);
  exception when others then insert into results values ('without repasse permission nobody closes a period', sqlerrm = 'not_authorized'); end;
end $$;
reset role;
insert into results select 'anon cannot execute payout RPCs or read the ledger',
  not has_function_privilege('anon', 'public.close_payout_period(uuid,date)', 'execute')
  and not has_function_privilege('anon', 'public.mark_payout_paid(uuid,date,text)', 'execute')
  and not has_table_privilege('anon', 'public.payout_entries', 'select');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 20 then raise exception 'seller payout contract failed'; end if;
end $$;
rollback;
