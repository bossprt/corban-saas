-- Contract test for 20261007_fin_bank_account_receipts_payouts_v1: the account that received a commission report goes
-- to its receipts (already posted and posted later); a closed report changes only its account; the account of payout
-- and receipt entries is set with an event, only by finance and only to an account of the company. Uses the test
-- company's existing confirmed report and payout entries. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/fin-bank-account-contract.sql

begin;

create temp table results (check_name text, ok boolean);
create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user,
       (select k.id from public.fin_bank_accounts k where k.organization_id = '00000000-0000-4000-8000-00000000c0b1' and k.is_active order by k.created_at limit 1) as bank,
       (select r.id from public.receipt_reports r where r.organization_id = '00000000-0000-4000-8000-00000000c0b1' and r.status <> 'draft'
          and exists (select 1 from public.commission_receipts c join public.fin_entries e on e.source = 'commission_receipt' and e.source_ref = c.id where c.report_id = r.id)
        order by r.created_at limit 1) as report,
       (select e.source_ref from public.fin_entries e where e.organization_id = '00000000-0000-4000-8000-00000000c0b1' and e.source = 'payout' and e.status = 'settled' limit 1) as payout;
grant select on ids to authenticated;
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

insert into results select 'fixture: company account, closed report with posted receipts and a paid payout',
  (select bank is not null and report is not null and payout is not null from ids);
-- A second company's account, to be refused.
insert into public.organizations (id, name, document, plan_type, is_active) values ('00000000-0000-4000-8000-0000000f1b01', 'Outra Empresa Banco', 'contrato-' || gen_random_uuid(), 'starter', true);
insert into public.fin_bank_accounts (organization_id, bank_name, label, is_active) values ('00000000-0000-4000-8000-0000000f1b01', 'Banco X', 'Conta de outra empresa', true);
create temp table other as select id from public.fin_bank_accounts where organization_id = '00000000-0000-4000-8000-0000000f1b01';
grant select on other to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', (select seller_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'a seller cannot set the account',
  pg_temp.err(format('select public.fin_assign_bank_account(%L, %L, array[%L]::uuid[], %L)', (select org from ids), 'payout', (select payout from ids), (select bank from ids))) like '%not_authorized%';
reset role;

select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'another company''s account is refused',
  pg_temp.err(format('select public.fin_assign_bank_account(%L, %L, array[%L]::uuid[], %L)', (select org from ids), 'payout', (select payout from ids), (select id from other))) like '%fin_bank_account_invalid%';
insert into results select 'a manual entry cannot be reached through this function',
  pg_temp.err(format('select public.fin_assign_bank_account(%L, %L, array[%L]::uuid[], %L)', (select org from ids), 'manual', (select payout from ids), (select bank from ids))) like '%fin_assign_invalid%';
insert into results select 'the payout entry takes the account; a second call changes nothing',
  public.fin_assign_bank_account((select org from ids), 'payout', array[(select payout from ids)], (select bank from ids)) = 1
  and public.fin_assign_bank_account((select org from ids), 'payout', array[(select payout from ids)], (select bank from ids)) = 0;
insert into results select 'the report''s account goes to its posted receipts',
  public.set_receipt_report_bank_account((select report from ids), (select bank from ids)) > 0;
reset role;

insert into results select 'every posted receipt of the report is in the account',
  not exists (select 1 from public.commission_receipts c join public.fin_entries e on e.source = 'commission_receipt' and e.source_ref = c.id
              where c.report_id = (select report from ids) and e.bank_account_id is distinct from (select bank from ids));
insert into results select 'each change is in the entry history (from / to)',
  exists (select 1 from public.fin_entry_events v join public.fin_entries e on e.id = v.entry_id
          where e.source = 'payout' and e.source_ref = (select payout from ids) and v.kind = 'edited' and v.detail->>'field' = 'bank_account' and (v.detail->>'to')::uuid = (select bank from ids));
insert into results select 'amounts and dates did not change',
  not exists (select 1 from public.fin_entry_events v where v.kind = 'edited' and v.detail->>'field' = 'bank_account' and v.detail ?| array['amount', 'settled_on']);
insert into results select 'a closed report still refuses any other change',
  pg_temp.err(format($q$select set_config('corban.receipt_rpc','on',true); update public.receipt_reports set file_name = 'x.xlsx' where id = %L$q$, (select report from ids))) like '%receipt_report_is_closed%';

-- A receipt posted after the account was set (here: its entry removed and posted again) is posted in that account.
create temp table one as select c.id from public.commission_receipts c where c.report_id = (select report from ids) limit 1;
delete from public.fin_entry_events where entry_id in (select e.id from public.fin_entries e where e.source = 'commission_receipt' and e.source_ref = (select id from one));
delete from public.fin_entries where source = 'commission_receipt' and source_ref = (select id from one);
select private.fin_post_receipt((select id from one));
insert into results select 'a receipt posted later takes the report''s account',
  (select bank_account_id from public.fin_entries where source = 'commission_receipt' and source_ref = (select id from one)) = (select bank from ids);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'fin bank account contract failed'; end if;
end $$;
rollback;
