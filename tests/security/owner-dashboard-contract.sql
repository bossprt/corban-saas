-- Contract test for 20261006184724_owner_dashboard_v1: the owner's dashboard is finance only, for the caller's company, and
-- its numbers are the sums of the contracts behind them (production, expected commission, sellers, received, per bank
-- and per day add up). Read only; one transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/owner-dashboard-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table board (b jsonb);
grant insert, select on board to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot open the owner dashboard',
  pg_temp.err(format('select public.owner_dashboard(%L, current_date - 30, current_date)', (select org from ids))) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'another company is refused',
  pg_temp.err(format('select public.owner_dashboard(%L, current_date - 30, current_date)', gen_random_uuid())) like '%not_authorized%';
insert into results select 'a wrong period is refused',
  pg_temp.err(format('select public.owner_dashboard(%L, current_date, current_date - 1)', (select org from ids))) like '%invalid_period%';
insert into board select public.owner_dashboard((select org from ids), current_date - 400, current_date);
reset role;

-- Reference sums read as the table owner.
insert into results select 'production = sum of the contracts paid to the client in the period',
  (select (b->'current'->>'production')::numeric from board)
  = (select coalesce(sum(coalesce(released_amount, requested_amount, 0)), 0) from public.proposals_v2
     where organization_id = (select org from ids) and status = 'paid' and paid_to_client_on between current_date - 400 and current_date);
insert into results select 'contracts count matches',
  (select (b->'current'->>'contracts')::int from board)
  = (select count(*) from public.proposals_v2 where organization_id = (select org from ids) and status = 'paid' and paid_to_client_on between current_date - 400 and current_date);
insert into results select 'per bank and per day add up to the total',
  (select (select coalesce(sum((x->>'production')::numeric), 0) from jsonb_array_elements(b->'banks') x) = (b->'current'->>'production')::numeric
      and (select coalesce(sum((x->>'production')::numeric), 0) from jsonb_array_elements(b->'series') x) = (b->'current'->>'production')::numeric from board);
insert into results select 'expected commission = received lines of the active calculations',
  (select (b->'current'->>'expected')::numeric from board)
  = (select coalesce(sum(l.amount * l.multiplier), 0) from public.proposals_v2 p
     join public.proposal_commission_calcs c on c.proposal_id = p.id and c.status = 'active'
     join public.proposal_commission_lines l on l.calc_id = c.id and l.line_kind = 'received'
     where p.organization_id = (select org from ids) and p.status = 'paid' and p.paid_to_client_on between current_date - 400 and current_date);
insert into results select 'received = receipts minus chargebacks in the period',
  (select (b->'current'->>'received')::numeric from board)
  = (select coalesce(sum(case when entry_kind = 'chargeback' then -amount else amount end), 0) from public.commission_receipts
     where organization_id = (select org from ids) and received_on between current_date - 400 and current_date);
insert into results select 'every block is present',
  (select b ?& array['period', 'current', 'previous', 'attention', 'series', 'sellers', 'banks', 'pipeline'] from board);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'owner dashboard contract failed'; end if;
end $$;
rollback;
