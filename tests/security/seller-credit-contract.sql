-- Contract test for 20260927000000_seller_credit_v1 (part C3, ADR-0041): the seller is credited when the contract is
-- paid to the client (and the physical file arrived), adjustments follow any later change, deferred is credited per
-- installment only to enabled sellers, closing goes by frequency, and a payment made outside Corban locks the contract.
-- Local test company: table v2 (6% à vista + 14% diferido on the gross), group Ouro (3% / 7%), seller bound to vendedor@.
-- Deferred triggers run at commit; the flush after each action (immediate, then deferred again) plays the commit.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/seller-credit-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0201'::uuid as tbl,
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
create function pg_temp.credited(p_label text) returns numeric language sql as $$
  select coalesce(sum(amount), 0) from public.payout_entries
  where proposal_id = (select id from made where label = p_label) and beneficiary_role = 'originator' and status = 'approved' and source in ('contract', 'receipt')
$$;
create function pg_temp.case_of(p_label text) returns uuid language sql as $$
  select id from public.operational_cases where proposal_id = (select id from made where label = p_label)
$$;
grant execute on function pg_temp.case_of(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente C3', '68999770009', null, 'manual') u;

-- Digital contract: credited only once paid to the client.
insert into made select 'dig', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-C3-1', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into results select 'digital by default (from the table)', (select formalization = 'digital' from public.proposals_v2 where id = (select id from made where label = 'dig'));
insert into results select 'nothing credited before the client is paid', (select waiting = 'client' from public.contract_credit((select id from made where label = 'dig')));
insert into results select 'the client payment date cannot be in the future',
  pg_temp.err(format('select public.move_operational_case(%L, %L, %L, null, %L)', pg_temp.case_of('dig'), 'paid', 'pago', current_date + 1)) = 'invalid_paid_on';
select public.move_operational_case(pg_temp.case_of('dig'), 'paid', 'Pago ao cliente', null, date '2026-09-10');
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;
insert into results select 'paid on 10/09 recorded', (select paid_to_client_on = date '2026-09-10' from public.proposals_v2 where id = (select id from made where label = 'dig'));
insert into results select 'paid: the seller is credited 300,00 (3% of 10.000,00)', pg_temp.credited('dig') = 300.00
  and exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'dig') and kind = 'commission' and source = 'contract' and amount = 300.00);
insert into results select 'no deferred credited with the contract', not exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'dig') and component_key = 'deferred');

-- The owner changes the payout (2%) and edits the amount (12.000,00): adjustments, never deletions.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_payout_override((select id from made where label = 'dig'), 'upfront', 'percentage', '2', 'combinado');
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;
insert into results select 'payout change becomes an adjustment (-100,00)', pg_temp.credited('dig') = 200.00
  and exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'dig') and kind = 'adjustment' and amount = -100.00);
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.update_contract((select id from made where label = 'dig'), '{"requested_amount":"12000.00"}'::jsonb, 'valor corrigido');
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into results select 'the paid date can be corrected, never to the future',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'dig'), jsonb_build_object('paid_to_client_on', current_date + 1), 'data')) = 'invalid_paid_on';
reset role;
insert into results select 'edit after paid: adjustment +40,00 (2% of 12.000,00 = 240,00)', pg_temp.credited('dig') = 240.00
  and (select count(*) from public.payout_entries where proposal_id = (select id from made where label = 'dig') and source = 'contract') = 3;

-- Physical contract: waits for the file received by the company.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_table_formalization((select tbl from ids), 'physical');
insert into made select 'fis', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-C3-2', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into results select 'physical from the table', (select formalization = 'physical' from public.proposals_v2 where id = (select id from made where label = 'fis'));
select public.move_operational_case(pg_temp.case_of('fis'), 'paid', 'Pago ao cliente', null, date '2026-09-23');
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into results select 'paid but physical: waiting for the file', (select waiting = 'physical' and credited = 0 from public.contract_credit((select id from made where label = 'fis')));
insert into results select 'milestones in order',
  pg_temp.err(format('select public.set_contract_physical(%L, %L, now())', (select id from made where label = 'fis'), 'sent')) = 'physical_out_of_order';
select public.set_contract_physical((select id from made where label = 'fis'), 'received', timestamptz '2026-09-23 17:28:00-05');
select public.set_contract_physical((select id from made where label = 'fis'), 'sent', timestamptz '2026-09-23 18:00:00-05');
select public.set_contract_physical((select id from made where label = 'fis'), 'bank', timestamptz '2026-09-24 09:00:00-05');
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;
insert into results select 'file received: credited 300,00', pg_temp.credited('fis') = 300.00;
insert into results select 'the milestones are in the history', (select count(*) = 3 from public.contract_events where proposal_id = (select id from made where label = 'fis') and kind = 'physical');

-- Deferred per installment, only for a seller enabled to receive it (installment = 7% of 10.000,00 over 120 = 5,83).
set local session_replication_role = replica;
insert into made select 'r1', gen_random_uuid();
insert into public.commission_receipts (id, organization_id, proposal_id, report_id, line_id, calc_id, entry_kind, component_key, installment_number, amount, expected_amount, reconciliation, received_on)
select (select id from made where label = 'r1'), (select org from ids), (select id from made where label = 'fis'), gen_random_uuid(), gen_random_uuid(), c.id, 'receipt', 'deferred', 1, 11.67, 11.67, 'matched', current_date
from public.proposal_commission_calcs c where c.proposal_id = (select id from made where label = 'fis') and c.status = 'active';
set local session_replication_role = origin;
select private.post_receipt((select id from made where label = 'r1'));
insert into results select 'seller not enabled: no deferred credit', not exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'fis') and component_key = 'deferred');
select set_config('corban.seller_rpc', 'on', true);
update public.commercial_sellers set receives_deferred = true where id = (select seller from ids);
select set_config('corban.seller_rpc', 'off', true);
set local session_replication_role = replica;
insert into made select 'r2', gen_random_uuid();
insert into public.commission_receipts (id, organization_id, proposal_id, report_id, line_id, calc_id, entry_kind, component_key, installment_number, amount, expected_amount, reconciliation, received_on)
select (select id from made where label = 'r2'), (select org from ids), (select id from made where label = 'fis'), gen_random_uuid(), gen_random_uuid(), c.id, 'receipt', 'deferred', 2, 11.67, 11.67, 'matched', current_date
from public.proposal_commission_calcs c where c.proposal_id = (select id from made where label = 'fis') and c.status = 'active';
set local session_replication_role = origin;
select private.post_receipt((select id from made where label = 'r2'));
insert into results select 'enabled seller: installment 2 credited 5,83',
  exists (select 1 from public.payout_entries where proposal_id = (select id from made where label = 'fis') and component_key = 'deferred' and installment_number = 2 and amount = 5.83 and source = 'receipt');

-- A payment made outside Corban (the Fabiola case): owner only, it locks the contract.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'only the owner registers an outside payment',
  pg_temp.err(format('select public.register_external_payout(%L, %L, %L)', (select id from made where label = 'dig'), '2026-09-11', 'pix')) = 'not_authorized';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.register_external_payout((select id from made where label = 'dig'), date '2026-09-11', 'Pago fora do Corban (2tech)');
insert into results select 'paid to the seller on 11/09', (select paid_on = date '2026-09-11' and reference = 'Pago fora do Corban (2tech)' from public.contract_credit((select id from made where label = 'dig')));
insert into results select 'paid: the contract is locked',
  pg_temp.err(format('select public.update_contract(%L, %L::jsonb, %L)', (select id from made where label = 'dig'), '{"term":"96"}', 'depois')) = 'contract_payout_received';

-- Closing by frequency: the seller is monthly; a weekly closing leaves them out.
insert into results select 'weekly closing does not touch a monthly seller', public.close_payout_period((select org from ids), current_date, 'weekly') = 0;
insert into results select 'monthly closing takes the open credits', public.close_payout_period((select org from ids), current_date, 'monthly') = 1;
insert into results select 'direct writes to payout entries are refused',
  pg_temp.err(format('insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, status) values (%L, %L, %L, 1, current_date, %L)',
    (select org from ids), (select account_id from public.payout_entries where proposal_id = (select id from made where label = 'fis') limit 1), 'bonus', 'approved')) <> 'ok';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'seller credit contract failed'; end if;
end $$;

rollback;
