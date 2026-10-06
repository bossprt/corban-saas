-- Contract test for 20261006_payout_batch_v1: the pay list shows, per account, exactly what "Pagar agora" pays today
-- (closing with a positive balance, closing with a negative carry and the debt limit, account model, an open statement);
-- paying with the shown amount records that amount; a different amount is refused; whoever may not pay sees nothing;
-- nobody sees or pays their own account. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-batch-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
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
create temp table listed (label text, amount numeric);
grant insert, select on listed to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'closing', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'debt', public.ensure_payout_account((select org from ids), null, (select fin_user from ids));
insert into made select 'withdrawal', public.ensure_payout_account((select org from ids), null, (select sup_user from ids));
insert into made select 'open', public.ensure_payout_account((select org from ids), null, (select v2 from ids));
insert into made select 'own', public.ensure_payout_account((select org from ids), null, (select admin_user from ids));
reset role;

select set_config('corban.payout_rpc', 'on', true);
update public.payout_accounts set model = 'closing' where id in (select id from made where label in ('closing', 'debt', 'open', 'own'));
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'withdrawal');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = x.l), 'bonus', x.v, current_date - 1, 'crédito de teste', 'approved'
from (values ('closing', 309.83), ('debt', 60.00), ('withdrawal', 150.00), ('own', 99.00)) as x(l, v);
-- The debt account closed before with R$ -100,00 to carry: with a 30% limit, 60,00 pays 42,00 and keeps -82,00.
update public.payout_settings set debt_limit_pct = 30 where organization_id = (select org from ids);
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'debt'), 'closing', current_date - 30, current_date - 20, 0, -100, 0, 0, -100, 'settled');
-- An open statement made by the old flow (R$ 77,00) is paid as it is.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status, requested_by)
values ((select org from ids), (select id from made where label = 'open'), 'closing', current_date - 5, current_date - 1, 0, 77, 0, 77, 0, 'pending', (select fin_user from ids));
select set_config('corban.payout_rpc', 'off', true);

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller gets an empty pay list',
  not exists (select 1 from public.payout_pay_list((select org from ids)));
insert into results select 'a seller cannot pay',
  pg_temp.err(format('select public.pay_account_now_checked(%L::uuid, current_date, %L, 309.83)', (select id from made where label = 'closing'), 'x')) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into listed select m.label, l.amount from public.payout_pay_list((select org from ids)) l join made m on m.id = l.account_id;
insert into results select 'pay list: closing 309,83; debt 42,00; withdrawal 150,00; open statement 77,00',
  (select coalesce(jsonb_object_agg(label, amount), '{}') from listed)
  = '{"closing": 309.83, "debt": 42.00, "withdrawal": 150.00, "open": 77.00}'::jsonb;
insert into results select 'the own account is not listed', not exists (select 1 from listed where label = 'own');
insert into results select 'a different amount is refused (amount_changed)',
  pg_temp.err(format('select public.pay_account_now_checked(%L::uuid, current_date, %L, 300)', (select id from made where label = 'closing'), 'PIX')) like '%amount_changed%';
insert into results select 'own account cannot be paid',
  pg_temp.err(format('select public.pay_account_now_checked(%L::uuid, current_date, %L, 99)', (select id from made where label = 'own'), 'PIX')) like '%cannot_pay_yourself%';
insert into results select 'each listed amount is paid',
  (select bool_and(pg_temp.err(format('select public.pay_account_now_checked(%L::uuid, current_date, %L, %s)', (select id from made where label = l.label), 'PIX lote', l.amount)) = 'ok') from listed l);
insert into results select 'each payment recorded exactly the listed amount',
  not exists (select 1 from listed l
                  where (select p.amount from public.payouts p where p.account_id = (select id from made where label = l.label) and p.status = 'paid' order by p.paid_at desc limit 1) is distinct from l.amount);
insert into results select 'debt account keeps -82,00 to carry',
  (select carry_out = -82.00 and debt_deduction = 18.00 from public.payouts where account_id = (select id from made where label = 'debt') and status = 'paid');
insert into results select 'after paying, the list is empty (nothing paid twice)',
  not exists (select 1 from public.payout_pay_list((select org from ids)) l where l.account_id in (select id from made where label in ('closing', 'debt', 'withdrawal', 'open')));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'payout batch contract failed'; end if;
end $$;
rollback;
