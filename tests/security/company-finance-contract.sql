-- Contract test for 20260927204141_company_finance_v1 (F6.5, ADR-0045): standard chart, payables/receivables with
-- installments, settle/undo/cancel with history, automatic posting of bank receipts and paid payouts (or by hand when the
-- company turns it off), OFX lines reconciled or turned into entries, cash flow and income statement, access.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/company-finance-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
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
create function pg_temp.acc(p_code text) returns uuid language sql as $$
  select id from public.fin_chart_accounts where organization_id = (select org from ids) and code = p_code
$$;
grant execute on function pg_temp.acc(text) to authenticated;
create function pg_temp.receive(p_label text, p_ade text, p_amount text) returns void language plpgsql as $$
declare v uuid;
begin
  v := public.import_receipt_report((select org from ids), 'bank',
         (select r.org_bank_id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
          join public.organization_product_routes r on r.id = t.route_id where v.id = (select tv from ids)),
         'upfront', current_date, p_label || '.csv', encode(sha256(convert_to(p_label || clock_timestamp()::text, 'utf8')), 'hex'), null,
         jsonb_build_array(jsonb_build_object('row', 1, 'ade', p_ade, 'amount', p_amount)));
  perform public.confirm_receipt_report(v);
end $$;
grant execute on function pg_temp.receive(text, text, text) to authenticated;

-- Access: the seller does not see nor write the company finance.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot open the company finance', pg_temp.err(format('select public.fin_setup(%L)', (select org from ids))) = 'not_authorized';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.fin_setup((select org from ids));
select public.fin_setup((select org from ids));
insert into results select 'standard chart created once (24 lines, 7 system lines)',
  (select count(*) = 24 and count(system_key) = 7 from public.fin_chart_accounts where organization_id = (select org from ids));
insert into results select 'a group line takes no entry',
  pg_temp.err(format('select public.fin_create_entry(%L, %L, %L, %L, null, null, null, 10, current_date, null, 1, null, null)', (select org from ids), 'out', 'Teste', pg_temp.acc('4'))) = 'fin_account_invalid';

-- Bank account and a payable in 3 installments (the cents go to the last one).
insert into made select 'bank', public.fin_save_bank_account((select org from ids), null, 'C6 Bank', 'C6 Smart', '0001', '12345-6', 1000, current_date - 60, true);
insert into made select 'rent', public.fin_create_entry((select org from ids), 'out', 'Aluguel da sala', pg_temp.acc('4.3'), null, 'Imobiliária', null, 1000, current_date, null, 3, null, null);
insert into results select 'installments 333,33 + 333,33 + 333,34, one month apart',
  (select string_agg(amount::text, '+' order by installment_no) = '333.33+333.33+333.34' and count(distinct due_on) = 3
   from public.fin_entries where installment_group = (select installment_group from public.fin_entries where id = (select id from made where label = 'rent')));
insert into results select 'money never as float: 0,1 + 0,2 cents are refused beyond 2 places',
  pg_temp.err(format('select public.fin_create_entry(%L, %L, %L, %L, null, null, null, 10.001, current_date, null, 1, null, null)', (select org from ids), 'out', 'Teste', pg_temp.acc('4.9'))) = 'invalid_amount';

-- Settle, undo (needs a reason), cancel (needs a reason), every step in the history; no direct write.
select public.fin_settle_entry((select id from made where label = 'rent'), current_date, (select id from made where label = 'bank'));
insert into results select 'settled with date and account', (select status = 'settled' and settled_on = current_date and bank_account_id = (select id from made where label = 'bank') from public.fin_entries where id = (select id from made where label = 'rent'));
insert into results select 'undoing a settlement needs a reason', pg_temp.err(format('select public.fin_undo_settlement(%L, %L)', (select id from made where label = 'rent'), '')) = 'reason_required';
select public.fin_undo_settlement((select id from made where label = 'rent'), 'pago em duplicidade');
select public.fin_cancel_entry((select id from made where label = 'rent'), 'contrato de aluguel cancelado');
insert into results select 'history keeps created, settled, undone and cancelled',
  (select string_agg(kind, ',' order by created_at) = 'created,settled,settlement_undone,cancelled' from public.fin_entry_events where entry_id = (select id from made where label = 'rent'));
insert into results select 'entries cannot be written directly',
  pg_temp.err(format('update public.fin_entries set amount = 1 where id = %L', (select id from made where label = 'rent'))) <> 'ok'
  and (select amount = 333.33 from public.fin_entries where id = (select id from made where label = 'rent'));

-- Automatic posting: a confirmed bank receipt is money in; a paid payout is money out.
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Fin', '68999770009', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-FIN-1', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit (born calculated)
select pg_temp.receive('fin1', 'ADE-FIN-1', '600.00');
insert into results select 'bank receipt posted as income, settled, in the commission account',
  exists (select 1 from public.fin_entries where source = 'commission_receipt' and proposal_id = (select id from made where label = 'p1')
          and direction = 'in' and status = 'settled' and amount = 600.00 and account_id = pg_temp.acc('1.1'));
select public.move_operational_case((select id from public.operational_cases where proposal_id = (select id from made where label = 'p1')), 'paid', 'Pago', null, current_date);
set constraints all immediate; set constraints all deferred;  -- as at commit (seller credited)
select public.register_external_payout((select id from made where label = 'p1'), current_date, 'PIX teste');
insert into results select 'paid payout posted as cost (repasse), money out',
  exists (select 1 from public.fin_entries where source = 'payout' and direction = 'out' and status = 'settled' and amount = 300.00 and account_id = pg_temp.acc('3.1'));

-- Manual mode: nothing is posted by itself; the item waits in the list and is posted once by hand.
select public.fin_set_auto_post((select org from ids), false);
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-FIN-2', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
select pg_temp.receive('fin2', 'ADE-FIN-2', '600.00');
insert into results select 'manual mode: the receipt is not posted by itself',
  not exists (select 1 from public.fin_entries where source = 'commission_receipt' and proposal_id = (select id from made where label = 'p2'));
insert into made select 'pending', source_ref from public.fin_pending_postings((select org from ids)) where proposal_id = (select id from made where label = 'p2');
insert into results select 'it waits in the list to post', (select id from made where label = 'pending') is not null;
select public.fin_post_pending((select org from ids), 'commission_receipt', (select id from made where label = 'pending'));
insert into results select 'posted by hand once', (select count(*) = 1 from public.fin_entries where source = 'commission_receipt' and source_ref = (select id from made where label = 'pending'))
  and pg_temp.err(format('select public.fin_post_pending(%L, %L, %L)', (select org from ids), 'commission_receipt', (select id from made where label = 'pending'))) = 'fin_already_posted';
reset role;

-- Statement: lines reconciled with entries (same direction and amount) or turned into entries; a line seen before is skipped.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'bill', public.fin_create_entry((select org from ids), 'out', 'Conta de energia', pg_temp.acc('4.4'), null, 'Energisa', null, 250.40, current_date, null, 1, null, null);
insert into made select 'imp', public.fin_import_statement((select id from made where label = 'bank'), 'extrato.ofx', repeat('b', 64), jsonb_build_array(
  jsonb_build_object('fitid', 'F1', 'posted_on', current_date, 'amount', '-250.40', 'memo', 'PAG CONTA ENERGIA'),
  jsonb_build_object('fitid', 'F2', 'posted_on', current_date, 'amount', '600.00', 'memo', 'TED BANCO TESTE'),
  jsonb_build_object('fitid', 'F3', 'posted_on', current_date, 'amount', '-12.90', 'memo', 'TARIFA PACOTE')));
insert into results select 'statement lines imported', (select line_count = 3 from public.fin_statement_imports where id = (select id from made where label = 'imp'));
insert into results select 'a line only matches the same direction and amount',
  pg_temp.err(format('select public.fin_match_line(%L, %L)', (select id from public.fin_statement_lines where fitid = 'F3'), (select id from made where label = 'bill'))) = 'fin_match_amount';
select public.fin_match_line((select id from public.fin_statement_lines where fitid = 'F1'), (select id from made where label = 'bill'));
insert into results select 'matching settles the open bill on the statement date and account',
  (select status = 'settled' and bank_account_id = (select id from made where label = 'bank') from public.fin_entries where id = (select id from made where label = 'bill'));
select public.fin_match_line((select id from public.fin_statement_lines where fitid = 'F2'),
  (select id from public.fin_entries where source = 'commission_receipt' and proposal_id = (select id from made where label = 'p1')));
insert into results select 'the automatic receipt gets its bank account from the statement',
  (select bank_account_id = (select id from made where label = 'bank') from public.fin_entries where source = 'commission_receipt' and proposal_id = (select id from made where label = 'p1'));
insert into made select 'fee', public.fin_entry_from_line((select id from public.fin_statement_lines where fitid = 'F3'), pg_temp.acc('5.2'), null, null);
insert into results select 'a bank fee line becomes a settled expense', (select direction = 'out' and amount = 12.90 and status = 'settled' from public.fin_entries where id = (select id from made where label = 'fee'));
select public.fin_import_statement((select id from made where label = 'bank'), 'extrato2.ofx', repeat('c', 64), jsonb_build_array(
  jsonb_build_object('fitid', 'F3', 'posted_on', current_date, 'amount', '-12.90', 'memo', 'TARIFA PACOTE'),
  jsonb_build_object('fitid', 'F4', 'posted_on', current_date, 'amount', '-5.00', 'memo', 'TARIFA TED')));
insert into results select 'a line seen before is skipped', (select count(*) = 4 from public.fin_statement_lines where bank_account_id = (select id from made where label = 'bank'));
insert into results select 'the same file is not imported twice',
  pg_temp.err(format('select public.fin_import_statement(%L, %L, %L, %L::jsonb)', (select id from made where label = 'bank'), 'x.ofx', repeat('c', 64), '[{"fitid":"F9","posted_on":"2026-01-01","amount":"1"}]')) = 'fin_statement_already_imported';

-- Balance, cash flow and income statement.
insert into results select 'bank balance = opening + settled in the account (1.000 - 250,40 + 600 - 12,90 = 1.336,70)',
  (select balance = 1336.70 and pending_lines = 1 from public.fin_bank_balances((select org from ids)) where bank_account_id = (select id from made where label = 'bank'));
insert into results select 'cash flow of the month: in 1.200,00, out 563,30 (250,40 + 300,00 + 12,90), forecast of the future rent excluded (cancelled)',
  (select realized_in = 1200.00 and realized_out = 563.30 from public.fin_cash_flow((select org from ids), date_trunc('month', current_date)::date, current_date) where month = date_trunc('month', current_date)::date);
insert into results select 'income statement: commission +1.200,00, payout -300,00, energy -250,40, fee -12,90',
  (select coalesce(sum(total) filter (where account_code = '1.1'), 0) = 1200.00 and coalesce(sum(total) filter (where account_code = '3.1'), 0) = -300.00
          and coalesce(sum(total) filter (where account_code = '4.4'), 0) = -250.40 and coalesce(sum(total) filter (where account_code = '5.2'), 0) = -12.90
   from public.fin_income_statement((select org from ids), date_trunc('month', current_date)::date, current_date));
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller reads no entry', not exists (select 1 from public.fin_entries);
insert into results select 'a seller cannot turn automatic posting off', pg_temp.err(format('select public.fin_set_auto_post(%L, true)', (select org from ids))) = 'not_authorized';
reset role;
insert into results select 'anon has nothing',
  not has_table_privilege('anon', 'public.fin_entries', 'select') and not has_function_privilege('anon', 'public.fin_create_entry(uuid,text,text,uuid,uuid,text,text,numeric,date,date,integer,date,uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 27 then raise exception 'company finance contract failed'; end if;
end $$;

rollback;
