-- Contract test for 20261020225536_sales_ranking_v1: the team's ranking counts contracts paid to the client in the
-- period per seller (released amount) and contracts typed; no commission or payout leaves; the external broker does not
-- see it. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/sales-ranking-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select m.user_id from public.organization_memberships m join public.organization_roles r on r.id = m.role_id
        where m.organization_id = '00000000-0000-4000-8000-00000000c0b1' and r.key = 'corretor' and m.status = 'active' limit 1) as broker,
       (now() at time zone 'America/Sao_Paulo')::date as today;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table got (j jsonb);
grant insert, select on got to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Ranking', '68999770021', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-RK-1', 'submitted') d;
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 5000, 4000, 150, 60, 'ADE-RK-2', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
reset role;
-- Fixture: contract 1 paid to the client today.
set local session_replication_role = replica;
update public.proposals_v2 set status = 'paid', paid_to_client_on = (select today from ids) where id = (select id from made where label = 'p1');
set local session_replication_role = origin;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into got select public.sales_ranking((select org from ids), (select today from ids) - 1, (select today from ids));
reset role;

insert into results select 'a seller sees the ranking with the paid contract (released amount)',
  exists (select 1 from got, jsonb_array_elements(j->'sellers') s
          where (s->>'seller_id')::uuid = (select seller from ids) and (s->>'paid_count')::int >= 1 and (s->>'paid_amount')::numeric >= 9500);
insert into results select 'contracts typed in the period are counted', (select (j->'totals'->>'typed_count')::int >= 2 from got);
insert into results select 'the funnel and the last paid contracts come along',
  (select j->'funnel' ? 'leads' and jsonb_array_length(j->'last_paid') >= 1 from got);
insert into results select 'no commission or payout leaves the ranking',
  (select j::text !~* '(commission|payout|repasse|originator)' from got);
insert into results select 'a period over 400 days is refused',
  pg_temp.err(format('select public.sales_ranking(%L, %L::date, %L::date)', (select org from ids), (select today from ids) - 500, (select today from ids))) like '%invalid_period%';

select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into results select 'the external broker does not see the ranking',
  (select broker from ids) is null
  or pg_temp.err(format('select public.sales_ranking(%L, %L::date, %L::date)', (select org from ids), (select today from ids), (select today from ids))) like '%not_authorized%';
reset role;
insert into results select 'anon cannot call it', not has_function_privilege('anon', 'public.sales_ranking(uuid, date, date)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'sales ranking contract failed'; end if;
end $$;
rollback;
