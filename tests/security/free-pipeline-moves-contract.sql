-- Contract test for 20261001190000_free_pipeline_moves_v1: a proposal moves from any stage to any stage (back, reopen),
-- the note is optional, "Paga" takes today when no date is given, every move is in the history, and money is protected:
-- only an admin or manager takes a contract out of "Paga", never once commission was received. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/free-pipeline-moves-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as supervisor_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
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
create function pg_temp.id(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.id(text) to authenticated;
create function pg_temp.case_of(p_label text) returns uuid language sql security definer as $$
  select c.id from public.operational_cases c where c.proposal_id = (select id from made where label = p_label) $$;
grant execute on function pg_temp.case_of(text) to authenticated;
create function pg_temp.stage(p_state text) returns uuid language sql security definer as $$
  select s.id from public.operational_stages s where s.organization_id = '00000000-0000-4000-8000-00000000c0b1' and s.canonical_state = p_state and s.is_active order by s.sort_order limit 1 $$;
grant execute on function pg_temp.stage(text) to authenticated;
create function pg_temp.mv(p_label text, p_state text) returns text language sql as $$
  select pg_temp.err(format('select public.move_case_to_stage(%L::uuid, %L::uuid, null, null, null)', pg_temp.case_of(p_label), pg_temp.stage(p_state)))
$$;
grant execute on function pg_temp.mv(text, text) to authenticated;
create function pg_temp.status(p_label text) returns text language sql security definer as $$
  select p.status || '/' || c.canonical_state from public.proposals_v2 p join public.operational_cases c on c.proposal_id = p.id where p.id = (select id from made where label = p_label) $$;
grant execute on function pg_temp.status(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Esteira', '68999770041', null, 'manual') u;
insert into made select 'a', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-EST-1', 'submitted') d;
insert into made select 'c', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-EST-3', 'submitted') d;
insert into made select 'b', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-EST-2', 'submitted') d;
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'back from Em análise to Aguardando digitação',
  pg_temp.mv('a', 'digitization_queue') = 'ok' and pg_temp.status('a') = 'digitization/digitization_queue';
insert into results select 'pendency without note or due date',
  pg_temp.mv('a', 'pending_external') = 'ok' and pg_temp.status('a') = 'submitted/pending_external';
-- Each move in its own statement: a subquery in the same statement may be evaluated before the move.
insert into results select 'straight to Paga without note', pg_temp.mv('a', 'paid') = 'ok';
insert into results select 'paid today when no date is given',
  (select paid_to_client_on = current_date and status = 'paid' from public.proposals_v2 where id = pg_temp.id('a'));
insert into results select 'admin takes a contract without money out of Paga', pg_temp.mv('a', 'cancelled') = 'ok';
insert into results select 'out of Paga: cancelled, paid date cleared',
  pg_temp.status('a') = 'cancelled/cancelled' and (select paid_to_client_on is null from public.proposals_v2 where id = pg_temp.id('a'));
insert into results select 'cancelled reopens',
  pg_temp.mv('a', 'submitted') = 'ok' and pg_temp.status('a') = 'submitted/submitted';
insert into results select 'rejected straight from Aguardando digitação',
  pg_temp.mv('b', 'digitization_queue') = 'ok' and pg_temp.mv('b', 'rejected') = 'ok' and pg_temp.status('b') = 'rejected/rejected';
insert into results select 'every move in the history',
  (select count(*) from public.operational_events e where e.operational_case_id = pg_temp.case_of('a') and e.event_type = 'state_transition') = 5;
insert into results select 'paid date in the future refused',
  pg_temp.err(format('select public.move_case_to_stage(%L::uuid, %L::uuid, null, null, %L::date)', pg_temp.case_of('a'), pg_temp.stage('paid'), current_date + 1)) like '%invalid_paid_on%';
insert into results select 'former call by state still works',
  pg_temp.err(format('select public.move_operational_case(%L::uuid, %L, null, null, null)', pg_temp.case_of('a'), 'approved')) = 'ok'
  and pg_temp.status('a') = 'approved/approved';
-- Paid with commission received: stays in Paga.
insert into results select 'paid again', pg_temp.mv('a', 'paid') = 'ok';
insert into results select 'commission received', pg_temp.err(format('select public.register_manual_receipt(%L::uuid, %L, %L, %L::date, null, %L)',
  pg_temp.id('a'), 'upfront', '600.00', current_date, 'caiu na conta')) = 'ok';
insert into results select 'contract with money does not leave Paga', pg_temp.mv('a', 'cancelled') like '%paid_contract_has_money%' and pg_temp.status('a') = 'paid/paid';
insert into results select 'unknown stage refused',
  pg_temp.err(format('select public.move_case_to_stage(%L::uuid, %L::uuid)', pg_temp.case_of('b'), gen_random_uuid())) like '%target_operational_stage_not_configured%';
reset role;

-- A supervisor with esteira.edit moves, but does not take a contract out of Paga; a seller without esteira.edit does not move.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'b to Paga', pg_temp.mv('b', 'paid') = 'ok';
reset role;
-- The supervisor sees every contract here (scope all), so only the Paga rule can stop the move.
update public.organization_roles r set scope = 'all' from public.organization_memberships m
where m.role_id = r.id and m.organization_id = (select org from ids) and m.user_id = (select supervisor_user from ids);
select pg_temp.act_as((select supervisor_user from ids));
set local role authenticated;
insert into results select 'supervisor cannot take out of Paga', pg_temp.mv('b', 'submitted') like '%leaving_paid_requires_manager%';
insert into results select 'supervisor moves an open contract', pg_temp.mv('c', 'approved') = 'ok';
reset role;
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'seller without esteira.edit cannot move', pg_temp.mv('b', 'submitted') not like 'ok';
reset role;

insert into results select 'anon runs none of them',
  not has_function_privilege('anon', 'public.move_case_to_stage(uuid,uuid,text,timestamp with time zone,date)', 'execute')
  and not has_function_privilege('anon', 'public.move_operational_case(uuid,text,text,timestamp with time zone,date)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 20 then raise exception 'free pipeline moves contract failed'; end if;
end $$;

rollback;
