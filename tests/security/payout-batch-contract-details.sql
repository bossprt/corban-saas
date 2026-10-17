-- Contract test for 20261017190216_payout_batch_contract_details_v1: a payment from the balance lists the contracts its
-- amount covered, oldest first, with "pago em parte" when it ended in the middle of one; a chargeback lowers its own
-- contract first; the contracts always add up to the amount paid; each contract brings its details. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-batch-contract-details.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'acct', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Saque', '68999770009', null, 'manual') u;
insert into made select 'p' || n, d.proposal_id
from generate_series(1, 3) n,
     lateral public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
       (select tv from ids), null, 10000, 9500, 250, 120, 'ADE-SQ-' || n, 'submitted') d;
reset role;

-- Fixture: the account pays from its balance; credits dated in the past so the order is clear.
set local session_replication_role = replica;
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'acct');
insert into public.payout_entries (organization_id, account_id, proposal_id, kind, amount, effective_on, description, status, created_at, source, beneficiary_role)
select (select org from ids), (select id from made where label = 'acct'), (select id from made where label = x.p), 'commission', x.v,
       current_date - x.d, 'comissão de teste', 'approved', now() - make_interval(days => x.d), 'contract', 'originator'
from (values ('p1', 100.00, 5), ('p2', 50.00, 4)) as x(p, v, d);
set local session_replication_role = origin;

-- First payment: 120,00 of the 150,00 balance.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'w1', public.request_payout_withdrawal((select id from made where label = 'acct'), 120.00, 'teste');
select public.pay_account_now((select id from made where label = 'acct'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX 1');
reset role;

-- Time passes: the first payment was 3 days ago; then a new contract and contract 2 lowered by 10,00.
set local session_replication_role = replica;
update public.payouts set requested_at = now() - interval '3 days' where id = (select id from made where label = 'w1');
insert into public.payout_entries (organization_id, account_id, proposal_id, kind, amount, effective_on, description, status, created_at, source, beneficiary_role)
select (select org from ids), (select id from made where label = 'acct'), (select id from made where label = x.p), x.k, x.v,
       current_date - x.d, 'teste', 'approved', now() - make_interval(days => x.d), 'contract', 'originator'
from (values ('p3', 'commission', 30.00, 2), ('p2', 'adjustment', -10.00, 1)) as x(p, k, v, d);
set local session_replication_role = origin;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'w2', public.pay_account_now((select id from made where label = 'acct'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX 2');
create temp table d1 as select public.payout_batch_detail((select batch_id from public.payouts where id = (select id from made where label = 'w1'))) j;
create temp table d2 as select public.payout_batch_detail((select batch_id from public.payouts where id = (select id from made where label = 'w2'))) j;
reset role;

create temp table c1 as select c.* from d1, jsonb_array_elements(d1.j->'lines'->0->'contracts') c;
create temp table c2 as select c.* from d2, jsonb_array_elements(d2.j->'lines'->0->'contracts') c;

insert into results select 'first payment: contract 1 whole (100,00), contract 2 in part (20,00)',
  (select count(*) = 2 from c1)
  and exists (select 1 from c1 where value->>'ade' = 'ADE-SQ-1' and (value->>'amount')::numeric = 100.00 and not (value->>'partial')::boolean)
  and exists (select 1 from c1 where value->>'ade' = 'ADE-SQ-2' and (value->>'amount')::numeric = 20.00 and (value->>'partial')::boolean);
insert into results select 'second payment is what was left (50,00)',
  (select amount = 50.00 from public.payouts where id = (select id from made where label = 'w2'));
insert into results select 'second payment: the chargeback lowered contract 2 (20,00 left of 30,00), contract 3 whole',
  (select count(*) = 2 from c2)
  and exists (select 1 from c2 where value->>'ade' = 'ADE-SQ-2' and (value->>'amount')::numeric = 20.00 and (value->>'partial')::boolean)
  and exists (select 1 from c2 where value->>'ade' = 'ADE-SQ-3' and (value->>'amount')::numeric = 30.00 and not (value->>'partial')::boolean);
insert into results select 'the contracts add up to the amount paid, in both payments',
  (select sum((value->>'amount')::numeric) from c1) = 120.00 and (select sum((value->>'amount')::numeric) from c2) = 50.00;
insert into results select 'the client name comes along',
  (select bool_and(value->>'client' = 'Cliente Saque') from c1);
insert into results select 'each contract brings bank, agreement, product and the amount released',
  (select bool_and(value->>'bank' is not null and value->>'agreement' is not null and value->>'product' is not null
                   and (value->>'released')::numeric = 9500.00 and value ? 'paid_to_client_on') from c1);
insert into results select 'the allocation is not callable by users',
  not has_function_privilege('authenticated', 'private.withdrawal_allocation(uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'payout withdrawal contracts failed'; end if;
end $$;
rollback;
