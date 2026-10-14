-- Contract test for 20261014000452_payout_batches_v1: every confirmation of payments is one batch; a single payment gets its
-- own; the list and the detail add up; "Desfazer lote" undoes all of a batch at once (admin, reason), never twice; a batch
-- cannot be borrowed by someone else. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/payout-batches-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'financeiro@corban-teste.local') as fin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       gen_random_uuid() as batch;
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

-- Three accounts with fresh credits.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'a', public.ensure_payout_account((select org from ids), (select broker_seller from ids), null);
insert into made select 'b', public.ensure_payout_account((select org from ids), null, (select sup_user from ids));
insert into made select 'c', public.ensure_payout_account((select org from ids), null, (select v1 from ids));
reset role;
select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = x.l), 'bonus', x.v, current_date - 1, 'crédito de teste', 'approved'
from (values ('a', 100.00), ('b', 50.00), ('c', 30.00)) as x(l, v);
select set_config('corban.payout_rpc', 'off', true);
create temp table due as select label, private.pay_now_amount(id) amount from made where label in ('a', 'b', 'c');
grant select on due to authenticated;

-- "Confirmar pagos" with two accounts: one batch.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'pa', public.pay_account_in_batch((select id from made where label = 'a'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX LOTE', (select amount from due where label = 'a'), (select batch from ids));
insert into made select 'pb', public.pay_account_in_batch((select id from made where label = 'b'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX LOTE', (select amount from due where label = 'b'), (select batch from ids));
-- A payment of one person outside the batch: a batch of its own.
insert into made select 'pc', public.pay_account_now((select id from made where label = 'c'), (now() at time zone 'America/Sao_Paulo')::date, 'PIX AVULSO');
reset role;

insert into results select 'both payments are in the batch the screen opened',
  (select count(*) = 2 from public.payouts where batch_id = (select batch from ids) and status = 'paid');
insert into results select 'the batch keeps date, proof, who paid',
  (select paid_on = (now() at time zone 'America/Sao_Paulo')::date and payment_reference = 'PIX LOTE' and origin = 'batch' and created_by = (select admin_user from ids)
   from public.payout_batches where id = (select batch from ids));
insert into results select 'a single payment gets its own batch',
  (select b.origin = 'single' and b.id <> (select batch from ids) from public.payouts p join public.payout_batches b on b.id = p.batch_id
   where p.id = (select id from made where label = 'pc'));

-- Someone else cannot put a payment into this batch.
select set_config('corban.payout_rpc', 'on', true);
insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status)
select (select org from ids), (select id from made where label = 'a'), 'bonus', 10.00, current_date - 1, 'crédito 2', 'approved';
select set_config('corban.payout_rpc', 'off', true);
create temp table due2 as select private.pay_now_amount((select id from made where label = 'a')) amount;
grant select on due2 to authenticated;
select pg_temp.act_as((select fin_user from ids));
set local role authenticated;
insert into results select 'a batch cannot be borrowed by another user',
  pg_temp.err(format('select public.pay_account_in_batch(%L::uuid, (now() at time zone ''America/Sao_Paulo'')::date, %L, %s, %L::uuid)', (select id from made where label = 'a'), 'PIX OUTRO',
    (select amount from due2), (select batch from ids))) like '%invalid_payout_batch%';
reset role;

-- List and detail.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the list shows the batch with its count and total',
  exists (select 1 from public.payout_batch_list((select org from ids)) l where l.id = (select batch from ids)
          and l.payouts = 2 and l.total::numeric = (select sum(amount) from due where label in ('a', 'b')) and l.undone = 0);
insert into results select 'the detail has one line per payment',
  (select jsonb_array_length(public.payout_batch_detail((select batch from ids))->'lines') = 2);

-- Undo the batch.
insert into results select 'a reason is required', pg_temp.err(format('select public.reverse_payout_batch(%L::uuid, %L)', (select batch from ids), 'x')) like '%reason_required%';
reset role;
select pg_temp.act_as((select fin_user from ids));
set local role authenticated;
insert into results select 'only an administrator undoes a batch',
  pg_temp.err(format('select public.reverse_payout_batch(%L::uuid, %L)', (select batch from ids), 'PIX não feito')) like '%not_authorized%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the administrator undoes the whole batch',
  pg_temp.err(format('select public.reverse_payout_batch(%L::uuid, %L)', (select batch from ids), 'PIX não feito')) = 'ok';
insert into results select 'a batch is undone only once',
  pg_temp.err(format('select public.reverse_payout_batch(%L::uuid, %L)', (select batch from ids), 'de novo')) like '%batch_already_reversed%';
insert into results select 'the list shows it undone',
  exists (select 1 from public.payout_batch_list((select org from ids)) l where l.id = (select batch from ids) and l.undone = 2 and l.reversed_at is not null);
reset role;
insert into results select 'both payments are reversed, the single one is untouched',
  (select count(*) = 2 from public.payouts where batch_id = (select batch from ids) and status = 'reversed')
  and (select status = 'paid' from public.payouts where id = (select id from made where label = 'pc'));
insert into results select 'the amounts to pay are back',
  (select private.pay_now_amount((select id from made where label = 'b')) = (select amount from due where label = 'b'));
insert into results select 'the bank outflows of the batch are cancelled',
  (select bool_and(status = 'cancelled') from public.fin_entries where source = 'payout' and source_ref in (select id from public.payouts where batch_id = (select batch from ids)));

-- The batch of a payment is written once; nobody moves a payment to another batch.
select set_config('corban.payout_rpc', 'on', true);
insert into results select 'a payment cannot be moved to another batch',
  pg_temp.err(format('update public.payouts set batch_id = (select batch_id from public.payouts where id = %L) where id = %L',
    (select id from made where label = 'pc'), (select id from made where label = 'pa'))) like '%payout_is_immutable%';
select set_config('corban.payout_rpc', 'off', true);

-- Who does not see Repasse does not see batches.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller does not see the batch list',
  pg_temp.err(format('select * from public.payout_batch_list(%L::uuid)', (select org from ids))) like '%not_authorized%'
  and not exists (select 1 from public.payout_batches where id = (select batch from ids));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'payout batches contract failed'; end if;
end $$;
rollback;
