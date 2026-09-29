-- Contract test for 20260929225821_pay_account_now_v1 and 20260929235900_pay_now_optional_proof_v1: one action pays an account (closing statement up to today, or the
-- available balance), records who paid, when and the proof, and moves the money exactly like the old three steps;
-- only for whoever may approve payouts, never to oneself, never a zero payment. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/pay-account-now-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'financeiro@corban-teste.local') as fin_user;
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
create function pg_temp.pay(p_label text, p_ref text) returns text language sql as $$
  select pg_temp.err(format('select public.pay_account_now(%L::uuid, current_date, %L)', (select id from made where label = p_label), p_ref))
$$;
grant execute on function pg_temp.pay(text, text) to authenticated;
create function pg_temp.balance(p_label text) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.payout_entries where account_id = (select id from made where label = p_label) and status = 'approved'
$$;
grant execute on function pg_temp.balance(text) to authenticated;

-- Two accounts: the broker (closing, company default) and a seller moved to the withdrawal model; both with approved
-- credits (a bonus stands for a reconciled commission here), one account with nothing.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'closing', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'withdrawal', public.ensure_payout_account((select org from ids), null, (select sup_user from ids));
insert into made select 'empty', public.ensure_payout_account((select org from ids), null, (select fin_user from ids));
reset role;
select set_config('corban.payout_rpc', 'on', true);
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'withdrawal');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = x.l), 'bonus', x.v, current_date - 1, 'crédito de teste', 'approved'
from (values ('closing', 309.83), ('withdrawal', 150.00)) as x(l, v);
select set_config('corban.payout_rpc', 'off', true);
create temp table before as select (select count(*) from public.fin_entries) fin;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot pay', pg_temp.pay('closing', 'PIX-TESTE-1') like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'future date refused',
  pg_temp.err(format('select public.pay_account_now(%L::uuid, current_date + 2, %L)', (select id from made where label = 'closing'), 'PIX-TESTE-1')) like '%invalid_paid_on%';
insert into results select 'closing account paid in one action', pg_temp.pay('closing', 'PIX-TESTE-1') = 'ok';
-- Proof optional (20260929235900_pay_now_optional_proof_v1): blank is recorded as not informed.
insert into results select 'withdrawal account paid without proof', pg_temp.pay('withdrawal', '') = 'ok';
insert into results select 'nothing to pay refused', pg_temp.pay('empty', 'PIX-TESTE-3') like '%nothing_to_pay%';
insert into results select 'second payment of the same balance refused', pg_temp.pay('closing', 'PIX-TESTE-4') like '%nothing_to_pay%';
reset role;

insert into results select 'closing: statement of R$ 309,83, paid, balance zero',
  (select count(*) = 1 and bool_and(kind = 'closing' and amount = 309.83 and status = 'paid' and payment_reference = 'PIX-TESTE-1'
           and approved_by = (select admin_user from ids) and paid_by = (select admin_user from ids) and note like '%sem segunda aprovação%')
   from public.payouts where account_id = (select id from made where label = 'closing'))
  and pg_temp.balance('closing') = 0;
insert into results select 'withdrawal: R$ 150,00 paid, balance zero',
  (select count(*) = 1 and bool_and(kind = 'withdrawal' and amount = 150.00 and status = 'paid' and payment_reference = 'Sem comprovante informado')
   from public.payouts where account_id = (select id from made where label = 'withdrawal'))
  and pg_temp.balance('withdrawal') = 0;
insert into results select 'statement entries closed by the payment',
  not exists (select 1 from public.payout_entries where account_id = (select id from made where label = 'closing') and kind = 'bonus' and statement_id is null);

-- An open statement made by the old flow is paid as it is (no second one).
select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
values ((select org from ids), (select id from made where label = 'closing'), 'bonus', 50.00, current_date, 'crédito de teste 2', 'approved');
select set_config('corban.payout_rpc', 'off', true);
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.close_payout_period((select org from ids), current_date, null);
insert into results select 'open statement paid instead of a new one', pg_temp.pay('closing', 'PIX-TESTE-5') = 'ok';
reset role;
insert into results select 'still one payout per statement',
  (select count(*) from public.payouts where account_id = (select id from made where label = 'closing')) = 2
  and not exists (select 1 from public.payouts where account_id = (select id from made where label = 'closing') and status <> 'paid');

-- Nobody pays themselves: the supervisor holds the withdrawal account.
select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
values ((select org from ids), (select id from made where label = 'withdrawal'), 'bonus', 10.00, current_date, 'crédito de teste 3', 'approved');
select set_config('corban.payout_rpc', 'off', true);
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'nobody pays themselves', pg_temp.pay('withdrawal', 'PIX-TESTE-6') ~ '(cannot_pay_yourself|not_authorized)';
reset role;

insert into results select 'company finance got the payments', (select count(*) from public.fin_entries) >= (select fin from before)
  and exists (select 1 from public.fin_entries where amount in (309.83, 150.00));
insert into results select 'anon cannot run it', not has_function_privilege('anon', 'public.pay_account_now(uuid,date,text)', 'execute');
insert into results select 'helper is private', not has_function_privilege('authenticated', 'private.close_payout_account(uuid,date,numeric)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 15 then raise exception 'pay account now contract failed'; end if;
end $$;

rollback;
