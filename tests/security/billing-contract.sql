-- Contract test for 20261103120000_billing_v1: the tables are closed to tenants; charges are created from the due day;
-- grace then block; another company or a seller cannot read the payment screen; paid/reversal rules; immutability;
-- an inactive subscription never blocks. Fictitious receiver. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/billing-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000bb001'::uuid as org_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_a;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Cobranca', 'cobranca-' || gen_random_uuid(), 'starter', true from ids;

-- Receiver and a subscription that started two months ago, due day 1, grace 0: last month's charge is blocking.
select public.platform_set_billing_settings(null, '12345678909', 'cpf', 'Fulano de Tal', 'Rio Branco');
select public.platform_set_subscription(null, org_a, 399.90, 1, 0, (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date, true) from ids;

insert into results values ('3 decimals refused',
  pg_temp.err(format('select public.platform_set_subscription(null, %L, 399.901, 1, 0, current_date, true)', (select org_a from ids))) like '%billing_invalid_amount%');

set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
insert into results select 'tenant cannot read settings', pg_temp.err('select * from public.platform_billing_settings') like '%permission denied%';
insert into results select 'tenant cannot read charges', pg_temp.err('select * from public.organization_charges') like '%permission denied%';
insert into results select 'tenant cannot call platform fn', pg_temp.err(format('select public.platform_mark_charge_paid(null, %L, current_date)', gen_random_uuid())) like '%permission denied%';
insert into results select 'admin sees blocked', (public.billing_status(org_a) ->> 'blocked')::boolean from ids;
insert into results select 'two charges created', jsonb_array_length(public.my_billing(org_a) -> 'charges') = 2 from ids;
insert into results select 'receiver shown to admin', public.my_billing(org_a) #>> '{receiver,name}' = 'FULANO DE TAL' from ids;
insert into results select 'other company refused', pg_temp.err(format('select public.billing_status(%L)', org_b)) like '%not_authorized%' from ids;
insert into results select 'other company payment screen refused', pg_temp.err(format('select public.my_billing(%L)', org_b)) like '%not_authorized%' from ids;
select pg_temp.act_as(seller_a) from ids;
insert into results select 'seller sees blocked', (public.billing_status(org_a) ->> 'blocked')::boolean from ids;
insert into results select 'seller cannot open payment screen', pg_temp.err(format('select public.my_billing(%L)', org_a)) like '%not_authorized%' from ids;
reset role;

-- Paying last month lifts the block (this month's charge, due day 1 and grace 0, still blocks only if past).
insert into results select 'pay twice refused', pg_temp.err(format('select public.platform_mark_charge_paid(null, %L, current_date); select public.platform_mark_charge_paid(null, %L, current_date)', c.id, c.id)) like '%billing_charge_already_paid%'
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
select public.platform_mark_charge_paid(null, c.id, current_date)
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
insert into results select 'future paid date refused', pg_temp.err(format('select public.platform_mark_charge_paid(null, %L, current_date + 1)', c.id)) like '%billing_invalid_paid_on%'
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
insert into results select 'reverse unpaid refused', pg_temp.err(format('select public.platform_reverse_charge(null, %L, %L)', c.id, 'engano'))  like '%billing_charge_not_paid%'
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
insert into results select 'reversal needs note', pg_temp.err(format('select public.platform_reverse_charge(null, %L, %L)', c.id, ' ')) like '%billing_reversal_note_required%'
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
insert into results select 'charges immutable', pg_temp.err(format('update public.organization_charges set amount = 1 where id = %L', c.id)) like '%billing_records_are_immutable%'
  from public.organization_charges c, ids where c.organization_id = org_a limit 1;
insert into results select 'events immutable', pg_temp.err('delete from public.organization_charge_events') like '%billing_records_are_immutable%';

-- Pay this month too: no block. Reverse it: blocked again (this month is past due day 1 with grace 0 unless today is day 1).
select public.platform_mark_charge_paid(null, c.id, current_date)
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
insert into results select 'all paid not blocked', not (private.billing_summary(org_a) ->> 'blocked')::boolean from ids;
select public.platform_reverse_charge(null, c.id, 'pagamento marcado por engano')
  from public.organization_charges c, ids where c.organization_id = org_a and c.period = (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date;
insert into results select 'reversal blocks again', (private.billing_summary(org_a) ->> 'blocked')::boolean from ids;

-- Grace: a subscription due today with 5 days of grace is open, not blocked.
select public.platform_set_subscription(null, org_b, 399.90, least(extract(day from now() at time zone 'America/Sao_Paulo')::int, 28), 5, now()::date, true) from ids;
insert into results select 'in grace not blocked', not (private.billing_summary(org_b) ->> 'blocked')::boolean from ids
  where extract(day from now() at time zone 'America/Sao_Paulo') <= 28;
insert into results select 'txid from company name', c.txid ~ '^EMPRESABCOBRANCA[0-9]{6}$' from public.organization_charges c, ids where c.organization_id = org_b;

-- Inactive subscription never blocks.
select public.platform_set_subscription(null, org_a, 399.90, 1, 0, (date_trunc('month', now() at time zone 'America/Sao_Paulo') - interval '1 month')::date, false) from ids;
insert into results select 'inactive not blocked', not (private.billing_summary(org_a) ->> 'blocked')::boolean from ids;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where ok is not true) then raise exception 'billing contract failed'; end if;
  if (select count(*) from results) < 20 then raise exception 'billing contract incomplete'; end if;
end $$;

rollback;
