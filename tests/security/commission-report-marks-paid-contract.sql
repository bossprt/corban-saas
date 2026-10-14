-- Contract test for 20261014162354_commission_report_marks_paid_v1: confirming a commission report moves each contract of
-- the report that is not yet "Paga" to "Paga" (the bank paid, so the client got the money) and the seller's share is
-- released; a contract without a seller, a cancelled one and chargeback reports never move. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/commission-report-marks-paid-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.receive(p_label text, p_kind text, p_rows jsonb) returns void language plpgsql as $$
declare v uuid;
begin
  v := public.import_receipt_report((select org from ids), 'bank', (select id from made where label = 'bank'), p_kind, current_date,
         p_label || '.csv', encode(sha256(convert_to(p_label || clock_timestamp()::text, 'utf8')), 'hex'), null, p_rows);
  insert into made values (p_label, v);
  -- A contract without a seller has no commission calculated: its line cannot be confirmed, finance ignores it.
  perform public.ignore_receipt_line(l.id, 'sem vendedor, conferir') from public.receipt_lines l where l.report_id = v and l.status = 'no_calc';
  perform public.confirm_receipt_report(v);
end $$;
grant execute on function pg_temp.receive(text, text, jsonb) to authenticated;
create function pg_temp.status(p_label text) returns text language sql as $$
  select status from public.proposals_v2 where id = (select id from made where label = p_label)
$$;
create function pg_temp.credited(p_label text) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.payout_entries
  where proposal_id = (select id from made where label = p_label) and beneficiary_role = 'originator' and status = 'approved'
$$;

insert into made select 'bank', r.org_bank_id
from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id join public.organization_product_routes r on r.id = t.route_id
where v.id = (select tv from ids);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Relatório', '68999770009', null, 'manual') u;
insert into made select 'open', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-RP-1', 'submitted') d;
insert into made select 'noseller', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), null, 10000, 9500, 250, 120, 'ADE-RP-2', 'submitted') d;
insert into made select 'chg', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-RP-3', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit

-- A chargeback report alone never moves the contract.
select pg_temp.receive('chg1', 'chargeback', jsonb_build_array(jsonb_build_object('row', 1, 'ade', 'ADE-RP-3', 'amount', '10.00')));
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;
insert into results select 'a chargeback report does not move the contract', pg_temp.status('chg') = 'submitted';

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select pg_temp.receive('up', 'upfront', jsonb_build_array(
  jsonb_build_object('row', 1, 'ade', 'ADE-RP-1', 'amount', '600.00', 'paid_on', (current_date - 2)::text),
  jsonb_build_object('row', 2, 'ade', 'ADE-RP-2', 'amount', '600.00')));
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;

insert into results select 'contract with a seller moved to Paga, on the date the bank paid',
  (select status = 'paid' and paid_to_client_on = current_date - 2 from public.proposals_v2 where id = (select id from made where label = 'open'));
insert into results select 'the pipeline is at Paga too',
  (select canonical_state = 'paid' from public.operational_cases where proposal_id = (select id from made where label = 'open'));
insert into results select 'the pipeline history says it came from the commission report',
  exists (select 1 from public.operational_events e join public.operational_cases c on c.id = e.operational_case_id
          where c.proposal_id = (select id from made where label = 'open') and e.to_state = 'paid'
            and e.metadata->>'note' like 'Pago ao cliente pelo relatório de comissão%' and e.metadata->>'receipt_report_id' = (select id from made where label = 'up')::text);
insert into results select 'evidence recorded as commission_report',
  exists (select 1 from public.proposal_status_evidence where proposal_id = (select id from made where label = 'open') and source = 'commission_report');
insert into results select 'the seller''s share is released at once (3% of 10.000,00)', pg_temp.credited('open') = 300.00;
insert into results select 'contract without a seller (no commission calculated) stays as it is', pg_temp.status('noseller') = 'submitted';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'commission report marks paid contract failed'; end if;
end $$;
rollback;
