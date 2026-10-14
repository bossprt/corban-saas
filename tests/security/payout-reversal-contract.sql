-- Contract test for 20261013230214_payout_reversal_v1: "Desfazer pagamento". Administrators only, with a reason; the payout
-- becomes reversed, the balance and the amount to pay come back exactly, the bank outflow is cancelled, the account can
-- be paid again; only the last payment of an account; nothing is deleted. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-reversal-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
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
create function pg_temp.balance(p_label text) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.payout_entries where account_id = (select id from made where label = p_label) and status = 'approved'
$$;
create function pg_temp.reverse(p_label text, p_reason text) returns text language sql as $$
  select pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = p_label), p_reason))
$$;
grant execute on function pg_temp.reverse(text, text) to authenticated;

-- A closing account and a withdrawal account, each with a fresh credit.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'closing', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'withdrawal', public.ensure_payout_account((select org from ids), null, (select sup_user from ids));
reset role;
select set_config('corban.payout_rpc', 'on', true);
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'withdrawal');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = x.l), 'bonus', x.v, current_date - 1, 'crédito de teste', 'approved'
from (values ('closing', 309.83), ('withdrawal', 150.00)) as x(l, v);
select set_config('corban.payout_rpc', 'off', true);

create temp table before as
select pg_temp.balance('closing') bal_c, private.pay_now_amount((select id from made where label = 'closing')) due_c,
       pg_temp.balance('withdrawal') bal_w, private.pay_now_amount((select id from made where label = 'withdrawal')) due_w;

-- Paid by the administrator (the payment that "was not made").
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'pay_c', public.pay_account_now((select id from made where label = 'closing'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX-NAO-FEITO');
insert into made select 'pay_w', public.pay_account_now((select id from made where label = 'withdrawal'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX-NAO-FEITO');
reset role;
insert into results select 'paid: the bank outflow exists',
  (select count(*) = 2 from public.fin_entries where source = 'payout' and status = 'settled' and source_ref in (select id from made where label in ('pay_c', 'pay_w')));

-- Who may undo, and with what.
select pg_temp.act_as((select fin_user from ids));
set local role authenticated;
insert into results select 'only an administrator undoes a payment',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_c'), 'nao foi pago')) like '%not_authorized%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'a reason is required',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_c'), 'x')) like '%reason_required%';
insert into results select 'the administrator undoes the closing payment',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_c'), 'PIX não foi feito')) = 'ok';
insert into results select 'a reversed payment cannot be undone twice',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_c'), 'de novo')) like '%payout_not_paid%';
reset role;

insert into results select 'the payout is reversed with who, when and why',
  (select status = 'reversed' and reversed_by = (select admin_user from ids) and reversed_at is not null and reversal_reason = 'PIX não foi feito'
   and paid_at is not null from public.payouts where id = (select id from made where label = 'pay_c'));
insert into results select 'the balance is back exactly', (select pg_temp.balance('closing') = bal_c from before);
insert into results select 'the amount to pay is back exactly', (select private.pay_now_amount((select id from made where label = 'closing')) = due_c from before);
insert into results select 'the bank outflow is cancelled with the reason in its history',
  (select status = 'cancelled' and settled_on is null from public.fin_entries where source = 'payout' and source_ref = (select id from made where label = 'pay_c'))
  and exists (select 1 from public.fin_entry_events v join public.fin_entries e on e.id = v.entry_id
              where e.source_ref = (select id from made where label = 'pay_c') and v.kind = 'cancelled' and v.reason = 'PIX não foi feito');
insert into results select 'nothing was deleted: the payout debit is still in the statement, offset by a credit',
  (select count(*) = 2 and sum(amount) = 0 from public.payout_entries where payout_id = (select id from made where label = 'pay_c'));
insert into results select 'the company outflow of the other payment is untouched',
  (select status = 'settled' from public.fin_entries where source = 'payout' and source_ref = (select id from made where label = 'pay_w'));

-- Paid again, for the same amount; the reversed one is no longer undoable.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'pay_c2', public.pay_account_now((select id from made where label = 'closing'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX-AGORA-SIM');
reset role;
insert into results select 'paid again for the same amount',
  (select amount = (select due_c from before) and status = 'paid' from public.payouts where id = (select id from made where label = 'pay_c2'));
insert into results select 'paid again: balance zero', pg_temp.balance('closing') = (select bal_c - due_c from before);

-- Withdrawal account: a later payment blocks undoing the earlier one.
select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = 'withdrawal'), 'bonus', 40.00, current_date - 1, 'crédito de teste 2', 'approved';
select set_config('corban.payout_rpc', 'off', true);
-- In real use each payment is its own transaction; here both share one clock, so the first is set one minute earlier.
set local session_replication_role = replica;
update public.payouts set requested_at = requested_at - interval '1 minute' where id = (select id from made where label = 'pay_w');
set local session_replication_role = origin;
create temp table before_w2 as select private.payout_available((select id from made where label = 'withdrawal')) avail;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'pay_w2', public.pay_account_now((select id from made where label = 'withdrawal'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX-2');
insert into results select 'only the last payment of an account can be undone',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_w'), 'nao foi pago')) like '%later_payout_exists%';
insert into results select 'the last withdrawal can be undone',
  pg_temp.err(format('select public.reverse_payout(%L::uuid, %L)', (select id from made where label = 'pay_w2'), 'nao foi pago')) = 'ok';
reset role;
insert into results select 'withdrawal: the undone amount is available again',
  private.payout_available((select id from made where label = 'withdrawal')) = (select avail from before_w2);

-- The payout record cannot be changed directly.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'no direct update of a reversed payout',
  pg_temp.err(format('update public.payouts set status = %L where id = %L', 'paid', (select id from made where label = 'pay_c'))) <> 'ok'
  or (select status = 'reversed' from public.payouts where id = (select id from made where label = 'pay_c'));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'payout reversal contract failed'; end if;
end $$;
rollback;
