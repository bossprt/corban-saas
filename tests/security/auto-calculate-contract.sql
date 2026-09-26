-- Contract test for 20260926170000_auto_calculate_v1 (ADR-0040): contracts are born calculated, whoever creates them;
-- a failure is recorded (the contract still exists); portal proposals are calculated only when approved.
-- The calculation runs at commit (deferred trigger); "set constraints all immediate" fires it inside this test.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/auto-calculate-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'corretor@corban-teste.local') as broker;
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

-- A seller (no permission to calculate by hand) registers a contract: it is calculated at commit.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Auto', '68999770009', null, 'manual') u;
insert into made select 'ok', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-AUTO-1', 'submitted') d;
insert into results select 'the seller still cannot calculate by hand',
  pg_temp.err(format('select public.calculate_contract_commission(%L)', (select id from made where label = 'ok'))) = 'not_authorized';
-- 150x has no line in the table (12 to 120x): the contract exists, the reason is recorded.
insert into made select 'fail', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 150, 'ADE-AUTO-2', 'submitted') d;
set constraints all immediate;
insert into results select 'the seller sees their commission right away',
  exists (select 1 from public.proposal_commission_lines l where l.line_kind = 'originator' and l.component_key = 'upfront' and l.amount = 300.00);
insert into results select 'a failed calculation is in the history with its reason',
  exists (select 1 from public.contract_events e where e.proposal_id = (select id from made where label = 'fail') and e.kind = 'calc_failed' and e.detail->>'code' = 'condition_not_found');
reset role;
insert into results select 'the contract is calculated by the rule (600,00 received, 300,00 to the seller)',
  exists (select 1 from public.proposal_commission_calcs c join public.proposal_commission_lines l on l.calc_id = c.id
          where c.proposal_id = (select id from made where label = 'ok') and c.status = 'active' and c.mode = 'group_values'
            and l.component_key = 'upfront' and l.line_kind = 'received' and l.amount = 600.00);
insert into results select 'the failed contract still exists, without a calculation',
  exists (select 1 from public.proposals_v2 where id = (select id from made where label = 'fail'))
  and not exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'fail'));
insert into results select 'the calculation was recorded as made by the seller', (select calculated_by = (select v1 from ids) from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'ok') and status = 'active');

-- Portal: nothing before the company approves; the approval calculates. Back to deferred, as in a real request: the
-- calculation runs at commit, when the proposal and its pending submission both exist.
set constraints all deferred;
select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into made select 'portal', public.submit_broker_proposal((select org from ids), '390.533.447-05', 'Cliente Portal Auto', '(68) 99977-0012', null,
  (select tv from ids), 10000, 9500, 250, 120, 'ADE-AUTO-3');
set constraints all immediate;
reset role;
insert into results select 'no calculation while the portal proposal waits for validation',
  not exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'portal'))
  and not exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'portal'));
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.decide_broker_proposal((select id from made where label = 'portal'), true, null);
set constraints all immediate;
reset role;
insert into results select 'the approval calculates (or records why it could not)',
  exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'portal') and status = 'active')
  or exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'portal') and kind = 'calc_failed');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'auto calculate contract failed'; end if;
end $$;

rollback;
