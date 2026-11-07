-- Contract test for 20261107043940_payout_safe_payment_v1 (audit 06/11/2026: G1, G2, E2, E9).
--   * payout_pay_now_amount returns exactly what the pay RPC pays (the pay list amount); null for the own account;
--     refused to whoever may not pay.
--   * pay_account_confirmed refuses a different amount and an invalid bank account, records nothing then; with the
--     right amount it pays and records the bank account in the same transaction.
--   * pay_payout_batch is all or nothing: one changed amount (or the own account, or bad lines) pays nobody and names
--     the account; when all match, one batch, every payment and the bank account at once.
--   * mark_payout_paid_with_bank records the bank account with the payment, or nothing.
--   * payout_batch_list / payout_batch_detail count only paid payments in total; undone ones apart.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-safe-payment-contract.sql

begin;

-- Sellers of its own for this test (copied from the seed seller), so the test depends only on the base seed.
insert into public.commercial_sellers (id, organization_id, name, seller_category, commission_group_id, branch_id, code)
select ('00000000-0000-4000-8000-0000000c5a0' || n)::uuid, s.organization_id, 'Vendedor Teste Lote Seguro ' || n, s.seller_category, s.commission_group_id, s.branch_id,
       (select coalesce(max(x.code), 0) from public.commercial_sellers x where x.organization_id = s.organization_id) + n
from public.commercial_sellers s, generate_series(1, 5) n where s.id = '00000000-0000-4000-8000-0000000c0801'
on conflict (id) do nothing;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c5a01'::uuid as broker_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
       (select id from auth.users where email = 'financeiro@corban-teste.local') as fin_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table got (label text, val text);
grant insert, select on got to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- 'ok', or the error message and its detail ("message | detail").
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare d text;
begin execute p_sql; return 'ok';
exception when others then get stacked diagnostics d = pg_exception_detail; return sqlerrm || ' | ' || coalesce(d, ''); end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.today() returns text language sql as $$ select ((now() at time zone 'America/Sao_Paulo')::date)::text $$;
grant execute on function pg_temp.today() to authenticated;
-- plpgsql and volatile: runs after the call before it in the same expression (a SQL function could be inlined and run first).
create function pg_temp.paid(p_label text) returns integer language plpgsql volatile as $$ begin return (
  select count(*)::integer from public.payouts p where p.account_id = (select id from made where label = p_label) and p.status = 'paid' ); end $$;
grant execute on function pg_temp.paid(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'closing', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'debt', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5a02'::uuid, null);
insert into made select 'withdrawal', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5a03'::uuid, null);
insert into made select 'open', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5a04'::uuid, null);
insert into made select 'mark', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5a05'::uuid, null);
insert into made select 'own', public.ensure_payout_account((select org from ids), null, (select admin_user from ids));
reset role;

-- Company bank accounts: an active one, an inactive one, and one of another company.
insert into public.fin_bank_accounts (organization_id, bank_name, label, is_active) values ((select org from ids), 'Banco Teste', 'Conta teste lote seguro', true);
insert into made select 'bank', id from public.fin_bank_accounts where organization_id = (select org from ids) and label = 'Conta teste lote seguro';
insert into public.fin_bank_accounts (organization_id, bank_name, label, is_active) values ((select org from ids), 'Banco Teste', 'Conta teste lote inativa', false);
insert into made select 'bank_off', id from public.fin_bank_accounts where organization_id = (select org from ids) and label = 'Conta teste lote inativa';
insert into public.organizations (id, name, document, plan_type, is_active)
values ('00000000-0000-4000-8000-0000000c5ab0', 'Empresa B Lote Seguro', 'lote-seguro-' || gen_random_uuid(), 'starter', true);
insert into public.fin_bank_accounts (organization_id, bank_name, label, is_active)
values ('00000000-0000-4000-8000-0000000c5ab0', 'Banco Teste', 'Conta teste outra empresa', true);
insert into made select 'bank_other', id from public.fin_bank_accounts where organization_id = '00000000-0000-4000-8000-0000000c5ab0';
insert into results select 'setup: every test record exists', (select count(*) = 3 from made where label like 'bank%');

select set_config('corban.payout_rpc', 'on', true);
update public.payout_accounts set model = 'closing' where id in (select id from made where label in ('closing', 'debt', 'open', 'own', 'mark'));
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'withdrawal');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = x.l), 'bonus', x.v, current_date - 1, 'crédito de teste', 'approved'
from (values ('closing', 309.83), ('debt', 60.00), ('withdrawal', 150.00), ('own', 99.00)) as x(l, v);
-- Debt account: carry -100,00, limit 30%: 60,00 pays 42,00 (the account balance would say -40,00).
update public.payout_settings set debt_limit_pct = 30 where organization_id = (select org from ids);
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'debt'), 'closing', current_date - 30, current_date - 20, 0, -100, 0, 0, -100, 'settled');
-- An open statement (R$ 77,00) is paid as it is.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status, requested_by)
values ((select org from ids), (select id from made where label = 'open'), 'closing', current_date - 5, current_date - 1, 0, 77, 0, 77, 0, 'pending', (select admin_user from ids));
-- An approved withdrawal (R$ 50,00) waiting for "Marcar pago".
insert into public.payouts (organization_id, account_id, kind, amount, status, requested_by)
values ((select org from ids), (select id from made where label = 'mark'), 'withdrawal', 50, 'approved', (select admin_user from ids));
select set_config('corban.payout_rpc', 'off', true);

-- Whoever may not pay.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot read the pay-now amount',
  pg_temp.err(format('select public.payout_pay_now_amount(%L::uuid)', (select id from made where label = 'closing'))) like 'not_authorized%';
insert into results select 'a seller cannot pay a batch',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX',
    jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83')))) like 'not_authorized%';
insert into results select 'a seller cannot confirm a payment',
  pg_temp.err(format('select public.pay_account_confirmed(%L::uuid, %L::date, %L, 309.83, null)', (select id from made where label = 'closing'), pg_temp.today(), 'PIX')) like 'not_authorized%';
insert into results select 'a seller cannot mark paid',
  pg_temp.err(format('select public.mark_payout_paid_with_bank((select id from public.payouts where account_id = %L::uuid and status = ''approved''), %L::date, %L, null)',
    (select id from made where label = 'mark'), pg_temp.today(), 'PIX 123')) like 'not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into got select m.label, public.payout_pay_now_amount(m.id) from made m where m.label in ('closing', 'debt', 'withdrawal', 'open', 'own');
insert into results select 'pay-now amount: closing 309.83, debt 42.00 (not the balance), withdrawal 150.00, open 77.00',
  (select jsonb_object_agg(label, val) from got where label <> 'own') = '{"closing": "309.83", "debt": "42.00", "withdrawal": "150.00", "open": "77.00"}'::jsonb;
insert into results select 'pay-now amount equals the pay list amount',
  not exists (select 1 from public.payout_pay_list((select org from ids)) l join made m on m.id = l.account_id join got g on g.label = m.label where g.val::numeric is distinct from l.amount);
insert into results select 'own account: no pay-now amount', (select val is null from got where label = 'own');

-- Single payment.
insert into results select 'confirm with a different amount is refused (amount_changed) and pays nothing',
  pg_temp.err(format('select public.pay_account_confirmed(%L::uuid, %L::date, %L, 60.00, null)', (select id from made where label = 'debt'), pg_temp.today(), 'PIX')) like 'amount_changed%'
  and pg_temp.paid('debt') = 0;
insert into results select 'confirm with a bank account of another company is refused and pays nothing',
  pg_temp.err(format('select public.pay_account_confirmed(%L::uuid, %L::date, %L, 42.00, %L::uuid)', (select id from made where label = 'debt'), pg_temp.today(), 'PIX', (select id from made where label = 'bank_other'))) like 'fin_bank_account_invalid%'
  and pg_temp.paid('debt') = 0;
insert into results select 'confirm with an inactive bank account is refused',
  pg_temp.err(format('select public.pay_account_confirmed(%L::uuid, %L::date, %L, 42.00, %L::uuid)', (select id from made where label = 'debt'), pg_temp.today(), 'PIX', (select id from made where label = 'bank_off'))) like 'fin_bank_account_invalid%';
insert into results select 'confirm with the shown amount runs',
  pg_temp.err(format('select public.pay_account_confirmed(%L::uuid, %L::date, %L, 77.00, %L::uuid)', (select id from made where label = 'open'), pg_temp.today(), '', (select id from made where label = 'bank'))) = 'ok';
insert into results select 'confirm pays exactly the shown amount',
  (select amount = 77 from public.payouts where account_id = (select id from made where label = 'open') and status = 'paid');
insert into results select 'confirm records the bank account on the outflow in the same call',
  (select f.bank_account_id = (select id from made where label = 'bank') from public.fin_entries f
   where f.source = 'payout' and f.source_ref = (select id from public.payouts where account_id = (select id from made where label = 'open') and status = 'paid'));

-- Batch: all or nothing.
insert into results select 'batch: no lines is refused',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX', '[]')) like 'invalid_batch_lines%';
insert into results select 'batch: a repeated account is refused',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX',
    jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83'),
                      jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83')))) like 'invalid_batch_lines%';
insert into results select 'batch: a bad amount text is refused',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX',
    jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309,83')))) like 'invalid_batch_lines%';
insert into results select 'batch: one changed amount pays nobody and names that account',
  (select e like 'amount_changed | %' and e like '%' || (select id from made where label = 'debt')::text || '%' and e not like '%' || (select id from made where label = 'closing')::text || '%'
   from (select pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX',
     jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83'),
                       jsonb_build_object('account', (select id from made where label = 'debt'), 'expected', '60.00')))) as e) x)
  and pg_temp.paid('closing') = 0 and pg_temp.paid('debt') = 0;
insert into results select 'batch: the own account pays nobody',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, null, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX',
    jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83'),
                      jsonb_build_object('account', (select id from made where label = 'own'), 'expected', '99.00')))) like 'cannot_pay_yourself%'
  and pg_temp.paid('closing') = 0;
insert into results select 'batch: an invalid bank account pays nobody',
  pg_temp.err(format('select public.pay_payout_batch(%L::uuid, %L::date, %L, %L::uuid, %L::jsonb)', (select org from ids), pg_temp.today(), 'PIX', (select id from made where label = 'bank_other'),
    jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83')))) like 'fin_bank_account_invalid%'
  and pg_temp.paid('closing') = 0;
insert into got select 'batch', public.pay_payout_batch((select org from ids), pg_temp.today()::date, 'PIX lote', (select id from made where label = 'bank'),
  jsonb_build_array(jsonb_build_object('account', (select id from made where label = 'closing'), 'expected', '309.83'),
                    jsonb_build_object('account', (select id from made where label = 'debt'), 'expected', '42.00'),
                    jsonb_build_object('account', (select id from made where label = 'withdrawal'), 'expected', '150')))::text;
insert into results select 'batch: all matching amounts are paid at once (3, total 501.83)',
  (select (val::jsonb->>'paid')::int = 3 and (val::jsonb->>'total')::numeric = 501.83 from got where label = 'batch')
  and pg_temp.paid('closing') = 1 and pg_temp.paid('debt') = 1 and pg_temp.paid('withdrawal') = 1;
insert into results select 'batch: every payment is in the returned batch',
  (select count(*) = 3 from public.payouts where batch_id = (select (val::jsonb->>'batch_id')::uuid from got where label = 'batch'));
insert into results select 'batch: the bank account is recorded on every outflow',
  (select count(*) = 3 and bool_and(f.bank_account_id = (select id from made where label = 'bank')) from public.fin_entries f
   where f.source = 'payout' and f.source_ref in (select id from public.payouts where batch_id = (select (val::jsonb->>'batch_id')::uuid from got where label = 'batch')));

-- Marcar pago with the bank account.
insert into results select 'mark paid with an invalid bank account records nothing',
  pg_temp.err(format('select public.mark_payout_paid_with_bank((select id from public.payouts where account_id = %L::uuid and status = ''approved''), %L::date, %L, %L::uuid)',
    (select id from made where label = 'mark'), pg_temp.today(), 'PIX 123', (select id from made where label = 'bank_off'))) like 'fin_bank_account_invalid%'
  and pg_temp.paid('mark') = 0;
insert into results select 'mark paid with the bank account runs',
  pg_temp.err(format('select public.mark_payout_paid_with_bank((select id from public.payouts where account_id = %L::uuid and status = ''approved''), %L::date, %L, %L::uuid)',
    (select id from made where label = 'mark'), pg_temp.today(), 'PIX 123', (select id from made where label = 'bank'))) = 'ok';
insert into results select 'mark paid records the payment and the bank account',
  (select f.bank_account_id = (select id from made where label = 'bank') from public.fin_entries f
       where f.source = 'payout' and f.source_ref = (select id from public.payouts where account_id = (select id from made where label = 'mark') and status = 'paid'));

-- Batch totals: undo one payment of the batch; total counts only the paid ones, the undone apart.
insert into results select 'undo one payment of the batch',
  pg_temp.err(format('select public.reverse_payout((select id from public.payouts where account_id = %L::uuid and status = ''paid''), %L)', (select id from made where label = 'withdrawal'), 'PIX não feito')) = 'ok';
insert into results select 'batch detail: total 351.83 paid, undone 150.00 apart',
  (select d->>'total' = '351.83' and d->>'undone_total' = '150.00'
   from (select public.payout_batch_detail((select (val::jsonb->>'batch_id')::uuid from got where label = 'batch')) as d) x);
insert into results select 'batch list: total 351.83 paid, 1 undone of 3, undone 150.00 apart',
  (select l.total = '351.83' and l.undone_total = '150.00' and l.payouts = 3 and l.undone = 1
   from public.payout_batch_list((select org from ids), 1000) l where l.id = (select (val::jsonb->>'batch_id')::uuid from got where label = 'batch'));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'payout safe payment contract failed'; end if;
  if (select count(*) from results) < 29 then raise exception 'payout safe payment contract: checks missing'; end if;
end $$;
rollback;
