-- Contract test for 20261107000504_payout_breakdown_v1 (owner 06/11/2026: the contracts of each seller payment).
--   * payout_pay_preview (before paying): contracts + other items = the exact amount "Pagar agora" pays
--     (payout_pay_now_amount), for a closing with previous balance, a closing with a negative balance (debt discount)
--     and an account-model withdrawal; difference 0.
--   * payout_breakdown of the payment made: the same contracts and totals; batch detail and person report carry it.
--   * a payment whose stored amount does not match its entries shows the difference (not hidden).
--   * another company's payment/account is refused; a seller sees only their own payments; no percentage keys.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-breakdown-contract.sql

begin;

insert into public.commercial_sellers (id, organization_id, name, seller_category, commission_group_id, branch_id, code)
select ('00000000-0000-4000-8000-0000000c5b0' || n)::uuid, s.organization_id, 'Vendedor Teste Composição ' || n, s.seller_category, s.commission_group_id, s.branch_id,
       (select coalesce(max(x.code), 0) from public.commercial_sellers x where x.organization_id = s.organization_id) + n
from public.commercial_sellers s, generate_series(1, 4) n where s.id = '00000000-0000-4000-8000-0000000c0801'
on conflict (id) do nothing;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from public.proposals_v2 where organization_id = '00000000-0000-4000-8000-00000000c0b1' order by id limit 1) as prop_a,
       (select id from public.proposals_v2 where organization_id = '00000000-0000-4000-8000-00000000c0b1' order by id offset 1 limit 1) as prop_b;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table got (label text, val jsonb);
grant insert, select on got to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok';
exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;
grant execute on function pg_temp.today() to authenticated;
-- contracts + others = total and difference 0, every amount summed as numeric.
create function pg_temp.adds_up(d jsonb) returns boolean language sql as $$
  select (d->>'difference')::numeric = 0
     and (select coalesce(sum((c->>'amount')::numeric), 0) from jsonb_array_elements(d->'contracts') c) = (d->>'contracts_total')::numeric
     and (select coalesce(sum((o->>'amount')::numeric), 0) from jsonb_array_elements(d->'others') o) = (d->>'others_total')::numeric
     and (d->>'contracts_total')::numeric + (d->>'others_total')::numeric = (d->>'total')::numeric
$$;
grant execute on function pg_temp.adds_up(jsonb) to authenticated;
create function pg_temp.kinds(d jsonb) returns text language sql as $$
  select string_agg(o->>'kind' || '=' || (o->>'amount'), ',' order by o->>'kind') from jsonb_array_elements(d->'others') o
$$;
grant execute on function pg_temp.kinds(jsonb) to authenticated;

insert into results select 'setup: two contracts of the company exist', (select prop_a is not null and prop_b is not null and prop_a <> prop_b from ids);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'closing', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5b01'::uuid, null);
insert into made select 'debt', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5b02'::uuid, null);
insert into made select 'withdrawal', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5b03'::uuid, null);
insert into made select 'mismatch', public.ensure_payout_account((select org from ids), '00000000-0000-4000-8000-0000000c5b04'::uuid, null);
insert into made select 'seller', public.ensure_payout_account((select org from ids), null, (select v1 from ids));
reset role;

-- Another company with a payout account and a payment.
insert into public.organizations (id, name, document, plan_type, is_active)
values ('00000000-0000-4000-8000-0000000c5bb0', 'Empresa B Composição', 'composicao-' || gen_random_uuid(), 'starter', true);

select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_accounts (organization_id, user_id) values ('00000000-0000-4000-8000-0000000c5bb0', (select admin_user from ids));
insert into made select 'other', id from public.payout_accounts where organization_id = '00000000-0000-4000-8000-0000000c5bb0';
insert into public.payouts (organization_id, account_id, kind, amount, status)
values ('00000000-0000-4000-8000-0000000c5bb0', (select id from made where label = 'other'), 'withdrawal', 10, 'pending');
insert into made select 'other_payout', id from public.payouts where account_id = (select id from made where label = 'other');

update public.payout_accounts set model = 'closing' where id in (select id from made where label in ('closing', 'debt', 'mismatch', 'seller'));
update public.payout_accounts set model = 'account' where id = (select id from made where label = 'withdrawal');
update public.payout_settings set debt_limit_pct = 30 where organization_id = (select org from ids);

-- Closing: contracts 1.000,00 + 234,56; vale -200,00; bonus 50,00; previous balance 10,00 -> pays 1.094,56.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'closing'), 'closing', current_date - 40, current_date - 30, 0, 10, 0, 0, 10, 'settled');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, proposal_id, beneficiary_role, source)
values ((select org from ids), (select id from made where label = 'closing'), 'commission', 1000.00, current_date - 3, 'comissão teste', 'approved', (select prop_a from ids), 'originator', 'contract'),
       ((select org from ids), (select id from made where label = 'closing'), 'commission', 234.56, current_date - 2, 'comissão teste', 'approved', (select prop_b from ids), 'originator', 'contract');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
values ((select org from ids), (select id from made where label = 'closing'), 'advance', -200.00, current_date - 2, 'vale teste', 'approved'),
       ((select org from ids), (select id from made where label = 'closing'), 'bonus', 50.00, current_date - 1, 'bônus teste', 'approved');

-- Debt: previous balance -100,00, contract 60,00, limit 30% -> discount 18,00, pays 42,00.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'debt'), 'closing', current_date - 40, current_date - 30, 0, -100, 0, 0, -100, 'settled');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, proposal_id, beneficiary_role, source)
values ((select org from ids), (select id from made where label = 'debt'), 'commission', 60.00, current_date - 1, 'comissão teste', 'approved', (select prop_a from ids), 'originator', 'contract');

-- Withdrawal (account model): contract 300,00 and bonus 20,00 -> pays 320,00 from the balance.
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, proposal_id, beneficiary_role, source, created_at)
values ((select org from ids), (select id from made where label = 'withdrawal'), 'commission', 300.00, current_date - 3, 'comissão teste', 'approved', (select prop_b from ids), 'originator', 'contract', now() - interval '3 days');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, created_at)
values ((select org from ids), (select id from made where label = 'withdrawal'), 'bonus', 20.00, current_date - 2, 'bônus teste', 'approved', now() - interval '2 days');

-- Mismatch: a statement recorded with 100,00 whose entries add up to 90,00.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'mismatch'), 'closing', current_date - 5, current_date - 1, 0, 100, 0, 100, 0, 'approved');
insert into made select 'mismatch_payout', id from public.payouts where account_id = (select id from made where label = 'mismatch');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, proposal_id, beneficiary_role, source, statement_id)
values ((select org from ids), (select id from made where label = 'mismatch'), 'commission', 90.00, current_date - 2, 'comissão teste', 'approved', (select prop_a from ids), 'originator', 'contract',
        (select id from made where label = 'mismatch_payout'));

-- The seller's own statement (approved) and a bonus.
insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status)
values ((select org from ids), (select id from made where label = 'seller'), 'closing', current_date - 5, current_date - 1, 0, 25, 0, 25, 0, 'approved');
insert into made select 'seller_payout', id from public.payouts where account_id = (select id from made where label = 'seller');
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, statement_id)
values ((select org from ids), (select id from made where label = 'seller'), 'bonus', 25.00, current_date - 2, 'bônus teste', 'approved', (select id from made where label = 'seller_payout'));
select set_config('corban.payout_rpc', 'off', true);

-- Before paying (admin).
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into got select 'pre_' || m.label, public.payout_pay_preview(m.id) from made m where m.label in ('closing', 'debt', 'withdrawal');
insert into results select 'preview total = pay-now amount (closing, debt, withdrawal)',
  (select bool_and((g.val->>'total') = public.payout_pay_now_amount(m.id)) from got g join made m on 'pre_' || m.label = g.label);
insert into results select 'preview adds up exactly (contracts + others = total, difference 0)',
  (select bool_and(pg_temp.adds_up(val)) and count(*) = 3 from got where label like 'pre_%');
insert into results select 'preview closing: 2 contracts 1234.56, vale/bonus listed, previous balance 10.00, total 1094.56',
  (select jsonb_array_length(val->'contracts') = 2 and val->>'contracts_total' = '1234.56' and val->>'total' = '1094.56'
          and pg_temp.kinds(val) = 'advance=-200.00,bonus=50.00,carry_in=10.00' from got where label = 'pre_closing');
insert into results select 'preview debt: contract 60.00, debt discount -18.00, total 42.00',
  (select val->>'contracts_total' = '60.00' and pg_temp.kinds(val) = 'debt_deduction=-18.00' and val->>'total' = '42.00' from got where label = 'pre_debt');
insert into results select 'preview withdrawal: contract 300.00, bonus 20.00, total 320.00',
  (select val->>'contracts_total' = '300.00' and pg_temp.kinds(val) = 'bonus=20.00' and val->>'total' = '320.00' from got where label = 'pre_withdrawal');
insert into results select 'contract items carry only ADE, client, bank, agreement, product, released, paid to client, amount (no percentages)',
  (select bool_and((select array_agg(k order by k) from jsonb_object_keys(c) k) <@ array['ade','agreement','amount','bank','client','kind','paid_to_client_on','partial','product','proposal_id','released'])
   from got g, jsonb_array_elements(g.val->'contracts') c where g.label like 'pre_%');

-- Pay all three in one batch; the payment shows the same composition.
insert into got select 'batch', public.pay_payout_batch((select org from ids), pg_temp.today(), 'PIX teste', null,
  (select jsonb_agg(jsonb_build_object('account', m.id, 'expected', g.val->>'total')) from got g join made m on 'pre_' || m.label = g.label));
insert into got select 'paid_' || m.label, public.payout_breakdown(p.id) from made m join public.payouts p on p.account_id = m.id and p.status = 'paid'
where m.label in ('closing', 'debt', 'withdrawal');
insert into results select 'paid payments: same contracts and totals as shown before paying',
  (select count(*) = 3 and bool_and(pg_temp.adds_up(a.val) and a.val->>'total' = b.val->>'total' and a.val->>'contracts_total' = b.val->>'contracts_total'
                                    and a.val->>'others_total' = b.val->>'others_total' and jsonb_array_length(a.val->'contracts') = jsonb_array_length(b.val->'contracts'))
   from got a join got b on a.label = 'paid_' || substr(b.label, 5) where b.label like 'pre_%');
insert into results select 'batch detail: every line carries contracts_total/others_total that add up to its amount',
  (select count(*) = 3 and bool_and((l->>'difference')::numeric = 0 and (l->>'contracts_total')::numeric + (l->>'others_total')::numeric = (l->>'amount')::numeric)
   from jsonb_array_elements(public.payout_batch_detail((select (val->>'batch_id')::uuid from got where label = 'batch'))->'lines') l);
insert into results select 'person report: the payment carries its breakdown',
  (select (pmt->>'contracts_total') = '1234.56' and (pmt->>'difference')::numeric = 0
   from jsonb_array_elements(public.payout_account_report((select id from made where label = 'closing'), pg_temp.today() - 1, pg_temp.today())->'payments') pmt);
insert into results select 'mismatch: the difference 10.00 is shown, not hidden',
  (select d->>'difference' = '10.00' and d->>'contracts_total' = '90.00' and d->>'total' = '100.00'
   from (select public.payout_breakdown((select id from made where label = 'mismatch_payout')) d) x);
insert into results select 'another company: payment breakdown refused',
  pg_temp.err(format('select public.payout_breakdown(%L::uuid)', (select id from made where label = 'other_payout'))) = 'not_authorized';
insert into results select 'another company: pay preview refused',
  pg_temp.err(format('select public.payout_pay_preview(%L::uuid)', (select id from made where label = 'other'))) = 'not_authorized';
reset role;

-- A seller: own payment yes, others no, no preview.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller sees the own payment breakdown',
  pg_temp.err(format('select public.payout_breakdown(%L::uuid)', (select id from made where label = 'seller_payout'))) = 'ok';
insert into results select 'seller: own payment adds up',
  pg_temp.adds_up(public.payout_breakdown((select id from made where label = 'seller_payout')));
insert into results select 'seller cannot see another person''s payment',
  pg_temp.err(format('select public.payout_breakdown(%L::uuid)', (select id from made where label = 'mismatch_payout'))) = 'not_authorized';
insert into results select 'seller cannot preview a payment',
  pg_temp.err(format('select public.payout_pay_preview(%L::uuid)', (select id from made where label = 'closing'))) = 'not_authorized';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'payout breakdown contract failed'; end if;
  if (select count(*) from results) < 17 then raise exception 'payout breakdown contract: checks missing'; end if;
end $$;
rollback;
