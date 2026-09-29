-- Contract test for 20260929170000_manual_commission_receipt_v1: a receipt registered by hand on the contract goes
-- through the same report, matching and confirmation as a bank file: expected value, zero tolerance (divergent to
-- Conciliação), duplicates refused, chargeback beyond what was received flagged divergent, company finance posted, finance only.
-- Uses the local test company and the commission seed (6% upfront on R$ 10.000,00 = R$ 600,00).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/manual-commission-receipt-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
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
create function pg_temp.reg(p_label text, p_kind text, p_amount text, p_on date, p_inst int) returns text language sql as $$
  select pg_temp.err(format('select public.register_manual_receipt(%L::uuid, %L, %L, %L::date, %s, %L)',
    (select id from made where label = p_label), p_kind, p_amount, p_on, coalesce(p_inst::text, 'null'), 'caiu na conta'))
$$;
grant execute on function pg_temp.reg(text, text, text, date, int) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Manual', '68999770019', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-MAN-1', 'submitted') d;
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-MAN-2', 'submitted') d;
insert into made select 'p3', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 200, 'ADE-MAN-3', 'submitted') d;
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'exact upfront registered', pg_temp.reg('p1', 'upfront', '600.00', current_date, null) = 'ok';
insert into results select 'second upfront on the same contract refused', pg_temp.reg('p1', 'upfront', '600.00', current_date, null) like '%manual_receipt_duplicate%';
insert into results select 'one cent off is accepted as divergent', pg_temp.reg('p2', 'upfront', '599.99', current_date, null) = 'ok';
insert into results select 'contract without commission refused', pg_temp.reg('p3', 'upfront', '400.00', current_date, null) like '%manual_receipt_no_calc%';
insert into results select 'chargeback within what was received registered', pg_temp.reg('p1', 'chargeback', '100.00', current_date, null) = 'ok';
-- As with a bank file: a chargeback beyond what is left is still booked (the money left the account), flagged divergent.
insert into results select 'chargeback beyond what is left booked as divergent', pg_temp.reg('p1', 'chargeback', '700.00', current_date, null) = 'ok';
insert into results select 'future date refused', pg_temp.reg('p2', 'deferred', '10.00', current_date + 1, null) like '%invalid_receipt_date%';
insert into results select 'amount with three decimals refused', pg_temp.reg('p2', 'deferred', '10.001', current_date, null) like '%invalid_receipt_amount%';
insert into results select 'installment only for deferred', pg_temp.reg('p2', 'upfront', '10.00', current_date, 2) like '%invalid_receipt_installment%';
insert into results select 'installment beyond the contract refused', pg_temp.reg('p2', 'deferred', '10.00', current_date, 500) like '%manual_receipt_installment_invalid%';
reset role;

insert into results select 'receipts in the ledger: matched, divergent, chargeback',
  (select count(*) filter (where entry_kind = 'receipt' and reconciliation = 'matched' and proposal_id = (select id from made where label = 'p1')) = 1
      and count(*) filter (where entry_kind = 'receipt' and reconciliation = 'divergent' and proposal_id = (select id from made where label = 'p2')) = 1
      and count(*) filter (where entry_kind = 'chargeback' and reconciliation = 'matched' and proposal_id = (select id from made where label = 'p1')) = 1
      and count(*) filter (where entry_kind = 'chargeback' and reconciliation = 'divergent' and proposal_id = (select id from made where label = 'p1')) = 1
   from public.commission_receipts where proposal_id in (select id from made where label in ('p1', 'p2')));
insert into results select 'each one is a confirmed manual report',
  (select bool_and(r.status = 'confirmed' and r.file_name = 'Lançamento manual') from public.commission_receipts c join public.receipt_reports r on r.id = c.report_id
   where c.proposal_id in (select id from made where label in ('p1', 'p2')));
insert into results select 'refused attempts left nothing behind',
  not exists (select 1 from public.receipt_reports r join public.receipt_lines l on l.report_id = r.id
              where l.proposal_id = (select id from made where label = 'p3'));
insert into results select 'the note travels with the line',
  exists (select 1 from public.receipt_lines l where l.proposal_id = (select id from made where label = 'p1') and l.bank_label = 'Lançamento manual: caiu na conta');

select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'supervisor cannot register', pg_temp.reg('p2', 'deferred', '10.00', current_date, null) ~ '(not_authorized|proposal_not_found)';
reset role;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot register', pg_temp.reg('p2', 'deferred', '10.00', current_date, null) ~ '(not_authorized|proposal_not_found)';
reset role;
insert into results select 'anon cannot run it', not has_function_privilege('anon', 'public.register_manual_receipt(uuid,text,text,date,integer,text)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 17 then raise exception 'manual commission receipt contract failed'; end if;
end $$;

rollback;
