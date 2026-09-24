-- Contract test for 20260924173938_commission_receipts_v1: matching by ADE within the paying source, zero tolerance,
-- deferred installments (next pending and the last one with the residual), duplicates, chargeback limit, file once,
-- confirmation rules, immutable ledger, divergence acceptance, alerts and finance-only visibility.
-- Uses the local test company and the commission seed (condition 6% upfront + 14% deferred on the gross amount).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/commission-receipts-contract.sql

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
create function pg_temp.line(p_report uuid, p_row int) returns text language sql as $$
  select l.status || coalesce(':' || l.expected_amount::text, '') || coalesce('#' || l.assigned_installment::text, '')
  from public.receipt_lines l where l.report_id = p_report and l.row_number = p_row
$$;
grant execute on function pg_temp.line(uuid, int) to authenticated;
insert into made select 'bank', r.org_bank_id
from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id join public.organization_product_routes r on r.id = t.route_id
where v.id = (select tv from ids);

-- Two proposals of the example (R$ 10.000,00 gross, 120 installments) with the commission calculated; a third without.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 10, 15, 75, true, 'regra do exemplo');
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Recebimento', '68999770009', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-REC-1', 'submitted') d;
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-REC-2', 'submitted') d;
insert into made select 'p3', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-REC-3', 'submitted') d;
select public.calculate_proposal_commission((select id from made where label = 'p1'));
select public.calculate_proposal_commission((select id from made where label = 'p2'));

-- Upfront report: exact, divergent by one cent, ADE printed differently, unknown, no commission, repeated.
insert into made select 'r1', public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront', '2026-09-15',
  'avista-setembro.xlsx', repeat('a', 64), 1799.98, jsonb_build_array(
    jsonb_build_object('row', 1, 'ade', 'ADE-REC-1', 'amount', '600.00', 'paid_on', '2026-09-10'),
    jsonb_build_object('row', 2, 'ade', 'ade rec 2', 'amount', '599.99'),
    jsonb_build_object('row', 3, 'ade', 'ADE-NAO-EXISTE', 'amount', '100.00'),
    jsonb_build_object('row', 4, 'ade', 'ADE-REC-3', 'amount', '400.00'),
    jsonb_build_object('row', 5, 'ade', 'ADE-REC-1', 'amount', '100.00')));
insert into results select 'exact amount matches to the cent', pg_temp.line((select id from made where label = 'r1'), 1) = 'ok:600.00';
insert into results select 'one cent off is divergent (zero tolerance); ADE compared by letters and digits', pg_temp.line((select id from made where label = 'r1'), 2) = 'divergent:600.00';
insert into results select 'unknown ADE is not found', pg_temp.line((select id from made where label = 'r1'), 3) = 'not_found';
insert into results select 'proposal without commission is flagged', pg_temp.line((select id from made where label = 'r1'), 4) = 'no_calc';
insert into results select 'second upfront line for the same proposal is a duplicate', pg_temp.line((select id from made where label = 'r1'), 5) = 'duplicate:600.00';
insert into results select 'report totals', (select line_count = 5 and lines_total = 1799.99 from public.receipt_reports where id = (select id from made where label = 'r1'));

do $$ begin
  begin
    perform public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront', '2026-09-01', 'copia.xlsx', repeat('a', 64), null,
      jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'X', 'amount', '1.00')));
    insert into results values ('same file cannot be imported twice', false);
  exception when others then insert into results values ('same file cannot be imported twice', sqlerrm = 'receipt_file_already_imported'); end;
  begin
    perform public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront', '2026-09-01', 'x.xlsx', repeat('b', 64), null,
      jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'X', 'amount', '11.666')));
    insert into results values ('amount with three decimals is rejected, never rounded', false);
  exception when others then insert into results values ('amount with three decimals is rejected, never rounded', sqlerrm = 'invalid_receipt_amount'); end;
  begin
    perform public.confirm_receipt_report((select id from made where label = 'r1'));
    insert into results values ('cannot confirm with unresolved lines', false);
  exception when others then insert into results values ('cannot confirm with unresolved lines', sqlerrm = 'receipt_report_has_unresolved_lines'); end;
end $$;

-- Resolve: calculate p3, ignore the unknown line, link the repeated line by hand, then ignore it.
select public.calculate_proposal_commission((select id from made where label = 'p3'));
select public.rematch_receipt_report((select id from made where label = 'r1'));
insert into results select 'after calculating, the proposal is compared (400 vs 600 divergent)', pg_temp.line((select id from made where label = 'r1'), 4) = 'divergent:600.00';
select public.ignore_receipt_line((select id from public.receipt_lines where report_id = (select id from made where label = 'r1') and row_number = 3), 'contrato de outra empresa');
select public.link_receipt_line((select id from public.receipt_lines where report_id = (select id from made where label = 'r1') and row_number = 5), (select id from made where label = 'p3'));
insert into results select 'manual link is compared too (repeated upfront is a duplicate)', pg_temp.line((select id from made where label = 'r1'), 5) = 'duplicate:600.00';
select public.ignore_receipt_line((select id from public.receipt_lines where report_id = (select id from made where label = 'r1') and row_number = 5), 'linha repetida no arquivo');

do $$ begin
  begin
    perform public.confirm_receipt_report((select id from made where label = 'r1'));
    insert into results values ('declared total must equal the lines', false);
  exception when others then insert into results values ('declared total must equal the lines', sqlerrm = 'receipt_total_mismatch'); end;
end $$;
reset role;

-- Seller: no access to reports, lines or ledger; cannot confirm.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller sees no receipt data',
  (select count(*) from public.receipt_reports) = 0 and (select count(*) from public.receipt_lines) = 0 and (select count(*) from public.commission_receipts) = 0;
do $$ begin
  begin
    perform public.confirm_receipt_report((select id from made where label = 'r1'));
    insert into results values ('seller cannot confirm', false);
  exception when others then insert into results values ('seller cannot confirm', sqlerrm = 'not_authorized'); end;
end $$;
reset role;

-- A second upfront report with the right total confirms: ledger written, report closed.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.discard_receipt_report((select id from made where label = 'r1'));
insert into made select 'r2', public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront', '2026-09-01',
  'avista-setembro-v2.xlsx', repeat('a', 64), 1599.99, jsonb_build_array(
    jsonb_build_object('row', 1, 'ade', 'ADE-REC-1', 'amount', '600.00'),
    jsonb_build_object('row', 2, 'ade', 'ADE-REC-2', 'amount', '599.99'),
    jsonb_build_object('row', 3, 'ade', 'ADE-REC-3', 'amount', '400.00')));
insert into results select 'discarded draft frees the file', (select status from public.receipt_reports where id = (select id from made where label = 'r2')) = 'draft';
insert into results select 'confirm writes one entry per line', public.confirm_receipt_report((select id from made where label = 'r2')) = 3;
insert into results select 'ledger: matched and divergent entries',
  (select string_agg(p.external_proposal_id || '=' || x.amount || '/' || x.reconciliation, ' ' order by p.external_proposal_id)
   from public.commission_receipts x join public.proposals_v2 p on p.id = x.proposal_id where x.report_id = (select id from made where label = 'r2'))
  = 'ADE-REC-1=600.00/matched ADE-REC-2=599.99/divergent ADE-REC-3=400.00/divergent';
do $$ begin
  begin
    update public.commission_receipts set amount = 1 where report_id = (select id from made where label = 'r2');
    insert into results values ('ledger cannot be edited', false);
  exception when others then insert into results values ('ledger cannot be edited', true); end;
  begin
    perform public.link_receipt_line((select id from public.receipt_lines where report_id = (select id from made where label = 'r2') and row_number = 1), null);
    insert into results values ('confirmed report lines are closed', false);
  exception when others then insert into results values ('confirmed report lines are closed', sqlerrm = 'receipt_report_is_closed'); end;
  begin
    perform public.accept_receipt_divergence((select id from public.commission_receipts where report_id = (select id from made where label = 'r2') and reconciliation = 'matched'), 'ok');
    insert into results values ('only divergent entries can be accepted', false);
  exception when others then insert into results values ('only divergent entries can be accepted', sqlerrm = 'receipt_not_divergent'); end;
end $$;
select public.accept_receipt_divergence(x.id, 'banco pagou um centavo a menos, aceito')
from public.commission_receipts x join public.proposals_v2 p on p.id = x.proposal_id where p.external_proposal_id = 'ADE-REC-2';
insert into results select 'accepted divergence no longer alerts; open one does',
  (select string_agg(a.reference, ',') from public.finance_alerts((select org from ids)) a where a.kind = 'divergence_open') = 'ADE-REC-3';

-- Deferred: next pending installment, explicit last installment with the residual, out of range, repeated installment.
insert into made select 'r3', public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'deferred', '2026-10-01',
  'diferido-outubro.csv', repeat('c', 64), null, jsonb_build_array(
    jsonb_build_object('row', 1, 'ade', 'ADE-REC-1', 'amount', '11.67'),
    jsonb_build_object('row', 2, 'ade', 'ADE-REC-1', 'amount', '11.67'),
    jsonb_build_object('row', 3, 'ade', 'ADE-REC-1', 'amount', '11.27', 'installment', '120'),
    jsonb_build_object('row', 4, 'ade', 'ADE-REC-1', 'amount', '11.67', 'installment', '121'),
    jsonb_build_object('row', 5, 'ade', 'ADE-REC-1', 'amount', '11.67', 'installment', '2')));
insert into results select 'deferred: first pending installment', pg_temp.line((select id from made where label = 'r3'), 1) = 'ok:11.67#1';
insert into results select 'deferred: next pending installment', pg_temp.line((select id from made where label = 'r3'), 2) = 'ok:11.67#2';
insert into results select 'deferred: last installment carries the residual', pg_temp.line((select id from made where label = 'r3'), 3) = 'ok:11.27#120';
insert into results select 'deferred: installment beyond the term', pg_temp.line((select id from made where label = 'r3'), 4) = 'installment_invalid#121';
insert into results select 'deferred: repeated installment', pg_temp.line((select id from made where label = 'r3'), 5) = 'duplicate:11.67#2';

-- Chargeback: up to what was received for the proposal.
insert into made select 'r4', public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), 'chargeback', '2026-10-01',
  'estornos-outubro.csv', repeat('d', 64), null, jsonb_build_array(
    jsonb_build_object('row', 1, 'ade', 'ADE-REC-1', 'amount', '600.00'),
    jsonb_build_object('row', 2, 'ade', 'ADE-REC-1', 'amount', '0.01')));
insert into results select 'chargeback within what was received', pg_temp.line((select id from made where label = 'r4'), 1) = 'ok:600.00';
insert into results select 'chargeback beyond what was received is divergent', pg_temp.line((select id from made where label = 'r4'), 2) = 'divergent:0.00';
select public.ignore_receipt_line((select id from public.receipt_lines where report_id = (select id from made where label = 'r4') and row_number = 2), 'valor sem origem');
select public.confirm_receipt_report((select id from made where label = 'r4'));
insert into results select 'chargeback alert', exists (select 1 from public.finance_alerts((select org from ids)) a where a.kind = 'chargeback' and a.amount = 600.00);
reset role;

-- Paid proposal without receipt after 30 days alerts (evidence moved back in time as the database owner).
select set_config('corban.paid_evidence_rpc', 'on', true);
update public.proposals_v2 set status = 'approved' where id in ((select id from made where label = 'p1'), (select id from made where label = 'p3'));
update public.proposals_v2 set status = 'paid' where id in ((select id from made where label = 'p1'), (select id from made where label = 'p3'));
update public.proposals_v2 set updated_at = now() - interval '70 days' where id in ((select id from made where label = 'p1'), (select id from made where label = 'p3'));
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'paid proposals with upfront received do not alert',
  not exists (select 1 from public.finance_alerts((select org from ids)) a where a.kind = 'paid_without_receipt');
insert into results select 'deferred missing after grace (70 days paid, none received for p3)',
  exists (select 1 from public.finance_alerts((select org from ids)) a where a.kind = 'deferred_missing' and a.proposal_id = (select id from made where label = 'p3'));
reset role;

-- Anonymous callers have no grants.
insert into results select 'anon cannot execute receipt RPCs',
  not has_function_privilege('anon', 'public.import_receipt_report(uuid,text,uuid,text,date,text,text,numeric,jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.confirm_receipt_report(uuid)', 'execute')
  and not has_table_privilege('anon', 'public.commission_receipts', 'select');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 30 then raise exception 'commission receipts contract failed'; end if;
end $$;
rollback;
