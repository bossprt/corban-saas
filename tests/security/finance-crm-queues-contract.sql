-- Contract test for 20261107001308_finance_crm_queues_v1: the commission receivable queue (any age, expected à vista),
-- several receipts at once in one transaction (one failure undoes all), the reconciliation by contract computed in the
-- database (period, open divergences, totals), the open lead with the same CPF (id only for who can work it) and the
-- service-only e-mail lookup. Finance only; sellers refused.
-- Uses the local test company and the commission seed (6% upfront on R$ 10.000,00 = R$ 600,00).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/finance-crm-queues-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (now() at time zone 'America/Sao_Paulo')::date as today;
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
create function pg_temp.bulk(p_items jsonb) returns text language sql as $$
  select pg_temp.err(format('select public.register_manual_receipts_bulk(%L::uuid, %L::jsonb, %L::date, null, %L)',
    (select org from ids), p_items, (select today from ids), 'em lote'))
$$;
grant execute on function pg_temp.bulk(jsonb) to authenticated;
create function pg_temp.item(p_label text, p_amount text) returns jsonb language sql as $$
  select jsonb_build_object('proposal_id', (select id from made where label = p_label), 'amount', p_amount)
$$;
grant execute on function pg_temp.item(text, text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Fila', '68999770019', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-FCQ-1', 'submitted') d;
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-FCQ-2', 'submitted') d;
insert into made select 'p3', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 200, 'ADE-FCQ-3', 'submitted') d;
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

-- Fixture: the three contracts paid to the client yesterday (as the database owner).
set local session_replication_role = replica;
update public.proposals_v2 set status = 'paid', paid_to_client_on = (select today from ids) - 1, updated_at = now() - interval '1 day'
where id in (select id from made where label in ('p1', 'p2', 'p3'));
set local session_replication_role = origin;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
create temp table recv as select * from public.commission_receivable((select org from ids), null, 0, 200, 0);
insert into results select 'receivable lists every paid contract without receipt',
  (select count(*) = 3 from recv where proposal_id in (select id from made where label in ('p1', 'p2', 'p3')));
insert into results select 'receivable carries the expected à vista commission',
  (select expected_amount::numeric = 600.00 from recv where proposal_id = (select id from made where label = 'p1'))
  and (select expected_amount is null from recv where proposal_id = (select id from made where label = 'p3'));
insert into results select 'receivable totals cover the whole filter',
  (select bool_and(total_count >= 3 and total_expected::numeric >= 1200.00) from recv);
insert into results select 'receivable older than 30 days leaves yesterday out',
  not exists (select 1 from public.commission_receivable((select org from ids), null, 30, 200, 0) r where r.proposal_id in (select id from made));
insert into results select 'receivable page size is bounded',
  pg_temp.err(format('select * from public.commission_receivable(%L::uuid, null, 0, 500, 0)', (select org from ids))) like '%invalid_page%';

-- Several at once: one contract without commission undoes the whole call.
insert into results select 'one failing item undoes all and names the contract',
  pg_temp.bulk(jsonb_build_array(pg_temp.item('p1', '600.00'), pg_temp.item('p3', '400.00'))) like '%bulk_receipt_item:ADE-FCQ-3:%manual_receipt_no_calc%';
insert into results select 'nothing recorded after the failure',
  not exists (select 1 from public.commission_receipts where proposal_id in (select id from made));
insert into results select 'the same contract twice is refused',
  pg_temp.bulk(jsonb_build_array(pg_temp.item('p1', '600.00'), pg_temp.item('p1', '600.00'))) like '%bulk_receipt_invalid%';
insert into results select 'empty list refused', pg_temp.bulk('[]'::jsonb) like '%bulk_receipt_invalid%';
insert into results select 'two receipts recorded at once',
  pg_temp.bulk(jsonb_build_array(pg_temp.item('p1', '600.00'), pg_temp.item('p2', '599.99'))) = 'ok';
insert into results select 'matched and divergent as one by one',
  (select count(*) filter (where proposal_id = (select id from made where label = 'p1') and reconciliation = 'matched') = 1
      and count(*) filter (where proposal_id = (select id from made where label = 'p2') and reconciliation = 'divergent') = 1
   from public.commission_receipts where proposal_id in (select id from made));
insert into results select 'received contracts leave the queue',
  not exists (select 1 from public.commission_receivable((select org from ids), null, 0, 200, 0) r where r.proposal_id in (select id from made where label in ('p1', 'p2')));

-- Reconciliation in the database.
create temp table rec as select * from public.commission_reconciliation((select org from ids), (select today from ids), (select today from ids), false, 200, 0);
insert into results select 'reconciliation: received in the period, by contract',
  (select upfront::numeric = 600.00 and net::numeric = 600.00 and jsonb_array_length(open_items) = 0 from rec where proposal_id = (select id from made where label = 'p1'))
  and (select upfront::numeric = 599.99 and jsonb_array_length(open_items) = 1 from rec where proposal_id = (select id from made where label = 'p2'));
insert into results select 'reconciliation totals include both',
  (select bool_and(sum_upfront::numeric >= 1199.99 and sum_net::numeric >= 1199.99 and total_count >= 2) from rec);
insert into results select 'reconciliation: only open divergences',
  exists (select 1 from public.commission_reconciliation((select org from ids), null, null, true, 200, 0) r where r.proposal_id = (select id from made where label = 'p2'))
  and not exists (select 1 from public.commission_reconciliation((select org from ids), null, null, true, 200, 0) r where r.proposal_id = (select id from made where label = 'p1'));
insert into results select 'reconciliation: a later period leaves them out',
  not exists (select 1 from public.commission_reconciliation((select org from ids), (select today from ids) + 1, null, false, 200, 0) r where r.proposal_id in (select id from made));

-- Lead with the same CPF.
insert into made select 'lead', public.create_sales_lead((select org from ids), 'Lead Fila', null, '11144477735', null, null);
insert into results select 'open lead with the same CPF found for who can work it',
  (select lead_id = (select id from made where label = 'lead') and workable from public.open_lead_with_cpf((select org from ids), '111.444.777-35'));
insert into results select 'unknown CPF finds nothing',
  not exists (select 1 from public.open_lead_with_cpf((select org from ids), '00000000191') x where x.lead_id = (select id from made where label = 'lead'));
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot list the receivable',
  pg_temp.err(format('select * from public.commission_receivable(%L::uuid)', (select org from ids))) like '%not_authorized%';
insert into results select 'seller cannot record receipts in bulk',
  pg_temp.bulk(jsonb_build_array(pg_temp.item('p3', '10.00'))) like '%not_authorized%';
insert into results select 'seller cannot read the reconciliation',
  pg_temp.err(format('select * from public.commission_reconciliation(%L::uuid)', (select org from ids))) like '%not_authorized%';
insert into results select 'seller never gets the id of a lead they cannot work',
  coalesce((select lead_id is null from public.open_lead_with_cpf((select org from ids), '11144477735') limit 1), true);
reset role;

insert into results select 'anon cannot run the new functions',
  not has_function_privilege('anon', 'public.commission_receivable(uuid,uuid,integer,integer,integer)', 'execute')
  and not has_function_privilege('anon', 'public.register_manual_receipts_bulk(uuid,jsonb,date,uuid,text)', 'execute')
  and not has_function_privilege('anon', 'public.commission_reconciliation(uuid,date,date,boolean,integer,integer)', 'execute')
  and not has_function_privilege('anon', 'public.open_lead_with_cpf(uuid,text)', 'execute');
insert into results select 'e-mail lookup is for the service role only',
  not has_function_privilege('authenticated', 'public.member_emails_service(uuid[])', 'execute')
  and not has_function_privilege('anon', 'public.member_emails_service(uuid[])', 'execute')
  and has_function_privilege('service_role', 'public.member_emails_service(uuid[])', 'execute');
insert into results select 'e-mail lookup answers several users at once',
  (select count(*) = 2 from public.member_emails_service(array[(select admin_user from ids), (select v1 from ids)]));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 25 then raise exception 'finance crm queues contract failed'; end if;
end $$;

rollback;
