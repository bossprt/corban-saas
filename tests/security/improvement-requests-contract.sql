-- Contract test for 20261009040423_improvement_requests_v1: a member sends a request and gets a protocol; the sender sees their
-- own, the company's administrator sees all of the company, a seller does not see a colleague's; another company sees
-- nothing and cannot send for it; nobody writes the tables directly; only a platform administrator answers (service
-- role), "declined" needs the reason, every change is in the history; nothing is deleted. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/improvement-requests-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000b0c01'::uuid as org_b,
       '00000000-0000-4000-8000-0000000b0c02'::uuid as admin_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_a,
       (select user_id from public.platform_administrators where status = 'active' limit 1) as platform_admin;
grant select on ids to authenticated, service_role;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated, service_role;
create temp table made (label text, v text);
grant insert, select on made to authenticated, service_role;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated, service_role;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Melhorias', 'melhorias-' || gen_random_uuid(), 'starter', true from ids;
insert into auth.users (id, email, aud, role) select admin_b, 'admin.b@melhorias.local', 'authenticated', 'authenticated' from ids;
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status) select org_b, admin_b, 'admin', 'active' from ids;
select set_config('corban.membership_rpc', 'off', true);

select pg_temp.act_as((select seller_a from ids));
set local role authenticated;
insert into made select 'seller_protocol', public.submit_improvement_request((select org_a from ids), 'improvement', 'Filtro por convênio', 'Quero filtrar os contratos por convênio na tela.', '/app/contratos');
insert into results select 'the protocol is MEL-year-number', (select v ~ '^MEL-[0-9]{4}-[0-9]{4,}$' from made where label = 'seller_protocol');
insert into results select 'a short text is refused',
  pg_temp.err(format('select public.submit_improvement_request(%L, %L, %L, %L, null)', (select org_a from ids), 'bug', 'ab', 'curto')) like '%invalid_title%';
insert into results select 'nobody writes the table directly',
  pg_temp.err(format('insert into public.improvement_requests (organization_id, protocol, kind, title, body, created_by) values (%L, %L, %L, %L, %L, %L)',
    (select org_a from ids), 'MEL-2026-9999', 'bug', 'Teste', 'Texto de teste longo', (select seller_a from ids))) like '%permission denied%';
insert into results select 'a member cannot answer (platform only)',
  pg_temp.err(format('select public.platform_answer_improvement_request(%L, %L, null, %L)', (select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')), 'approved', (select seller_a from ids))) like '%permission denied%';
reset role;

select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into made select 'admin_protocol', public.submit_improvement_request((select org_a from ids), 'question', 'Como exportar', 'Como exporto os contratos para o Excel?', null);
insert into results select 'the company administrator sees both requests of the company',
  (select count(*) = 2 from public.improvement_requests where protocol in (select v from made));
reset role;

select pg_temp.act_as((select seller_a from ids));
set local role authenticated;
insert into results select 'a seller sees only their own request',
  (select count(*) = 1 from public.improvement_requests where protocol in (select v from made));
reset role;

select pg_temp.act_as((select admin_b from ids));
set local role authenticated;
insert into results select 'another company sees nothing', (select count(*) = 0 from public.improvement_requests where protocol in (select v from made));
insert into results select 'another company cannot send for company A',
  pg_temp.err(format('select public.submit_improvement_request(%L, %L, %L, %L, null)', (select org_a from ids), 'bug', 'Teste B', 'Tentando enviar pela empresa A')) like '%not_authorized%';
reset role;

-- The platform administrator answers through the service role.
set local role service_role;
insert into results select 'an actor who is not a platform administrator is refused',
  pg_temp.err(format('select public.platform_answer_improvement_request(%L, %L, null, %L)', (select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')), 'approved', (select admin_a from ids))) like '%not_authorized%';
insert into results select 'declined needs the reason',
  pg_temp.err(format('select public.platform_answer_improvement_request(%L, %L, null, %L)', (select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')), 'declined', (select platform_admin from ids))) like '%response_required%';
select public.platform_answer_improvement_request((select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')), 'analyzing', null, (select platform_admin from ids));
select public.platform_answer_improvement_request((select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')), 'approved', 'Vamos fazer na próxima semana.', (select platform_admin from ids));
reset role;

insert into results select 'the request shows the answer; the history has every change',
  (select status = 'approved' and response = 'Vamos fazer na próxima semana.' from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol'))
  and (select string_agg(to_status, '>' order by created_at) = 'received>analyzing>approved' from public.improvement_request_events
       where request_id = (select id from public.improvement_requests where protocol = (select v from made where label = 'seller_protocol')));
insert into results select 'nothing is deleted',
  pg_temp.err(format('delete from public.improvement_requests where protocol = %L', (select v from made where label = 'seller_protocol'))) like '%improvement_records_are_kept%';
insert into results select 'the text cannot be changed',
  pg_temp.err(format('update public.improvement_requests set title = %L where protocol = %L', 'Outro', (select v from made where label = 'seller_protocol'))) like '%identity_is_immutable%';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'improvement requests contract failed'; end if;
end $$;
rollback;
