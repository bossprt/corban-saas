-- Contract test for 20260925000807_broker_portal_v1 (F7): portal proposals wait for validation by someone else, an
-- existing client is never shown to the broker, no commission before validation, refusal needs a reason, portal
-- documents are private to the sender and the team, and a portal invitation lands with the 'corretor' role.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/broker-portal-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
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
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

-- The seller's client (CPF 529.982.247-25) exists before the broker sends anything.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 10, 15, 75, true, 'regra do teste');
reset role;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client_v1', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente do Vendedor', '68999770011', null, 'manual') u;
reset role;

-- The broker sends a new client (with ADE) and the seller's client (without ADE).
select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into made select 'p_new', public.submit_broker_proposal((select org from ids), '390.533.447-05', 'Cliente Novo do Corretor', '(68) 99977-0012', 'novo@exemplo.com',
  (select tv from ids), 10000, 9500, 250, 120, 'ADE-PORTAL-1');
insert into made select 'p_old', public.submit_broker_proposal((select org from ids), '52998224725', 'Nome Digitado Pelo Corretor', '68999770099', null,
  (select tv from ids), 5000, 4800, 150, 84, null);
insert into made select 'p_doc', public.submit_broker_proposal((select org from ids), '11144477735', 'Cliente Documento', null, null,
  (select tv from ids), 3000, 2900, 100, 48, null);
insert into results select 'broker sees own portal proposals as pending',
  (select count(*) from public.proposal_submissions where status = 'pending' and proposal_id in (select id from made where label in ('p_new','p_old','p_doc'))) = 3;
insert into results select 'broker never sees the existing client of another seller',
  not exists (select 1 from public.clients where cpf = '52998224725');
insert into results select 'broker sees the client he created',
  exists (select 1 from public.clients where cpf = '39053344705');
insert into results select 'the proposal keeps what the broker typed',
  (select customer_snapshot->>'full_name' from public.proposals_v2 where id = (select id from made where label = 'p_old')) = 'Nome Digitado Pelo Corretor';
insert into results select 'same bank and ADE twice is refused',
  pg_temp.err(format($q$select public.submit_broker_proposal(%L, '39053344705', 'Outro', null, null, %L, 1000, 900, 50, 12, 'ADE-PORTAL-1')$q$, (select org from ids), (select tv from ids))) = 'proposal_already_exists';
insert into results select 'broker cannot validate (no esteira.edit)',
  pg_temp.err(format($q$select public.decide_broker_proposal(%L, true, null)$q$, (select id from made where label = 'p_new'))) = 'not_authorized';
insert into results select 'direct write to proposal_submissions is refused',
  pg_temp.err(format($q$update public.proposal_submissions set status = 'validated' where proposal_id = %L$q$, (select id from made where label = 'p_new'))) is not null;
-- A document of a pending proposal: storage object under <org>/portal/<proposal>/ then the record.
insert into storage.objects (bucket_id, name, owner_id)
values ('corban-documents', (select org from ids)::text || '/portal/' || (select id from made where label = 'p_doc')::text || '/doc1/rg.pdf', (select broker from ids)::text);
select public.record_submission_document((select id from made where label = 'p_doc'), 'RG', (select org from ids)::text || '/portal/' || (select id from made where label = 'p_doc')::text || '/doc1/rg.pdf',
  'rg.pdf', 'application/pdf', 1234, repeat('a', 64));
insert into results select 'broker records a document of his pending proposal',
  (select count(*) from public.proposal_submission_documents where proposal_id = (select id from made where label = 'p_doc')) = 1;
insert into results select 'broker cannot upload into a proposal that is not his',
  pg_temp.err(format($q$insert into storage.objects (bucket_id, name, owner_id) values ('corban-documents', %L, %L)$q$,
    (select org from ids)::text || '/portal/' || gen_random_uuid()::text || '/x/a.pdf', (select broker from ids)::text)) is not null;
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'another seller cannot read portal documents of a proposal he does not see',
  not exists (select 1 from storage.objects where name like '%/portal/%');
reset role;

-- The team: queue, no commission before validation, refusal needs a reason, validation opens the pipeline.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'queue flags the existing client and its portfolio, not the new one',
  (select client_preexisted and client_owner_name = 'Vendedor Teste' from public.broker_submission_queue((select org from ids)) where proposal_id = (select id from made where label = 'p_old'))
  and (select not client_preexisted and client_owner_name is null from public.broker_submission_queue((select org from ids)) where proposal_id = (select id from made where label = 'p_new'));
insert into results select 'no commission is calculated before validation',
  pg_temp.err(format($q$select public.calculate_proposal_commission(%L)$q$, (select id from made where label = 'p_new'))) = 'proposal_pending_validation';
insert into results select 'refusal without a reason is refused',
  pg_temp.err(format($q$select public.decide_broker_proposal(%L, false, null)$q$, (select id from made where label = 'p_old'))) = 'reason_required';
select public.decide_broker_proposal((select id from made where label = 'p_old'), false, 'Cliente já atendido por outro vendedor');
insert into results select 'refused proposal is cancelled with the reason',
  (select p.status = 'cancelled' and s.status = 'rejected' and s.decision_reason = 'Cliente já atendido por outro vendedor'
   from public.proposals_v2 p join public.proposal_submissions s on s.proposal_id = p.id where p.id = (select id from made where label = 'p_old'));
insert into results select 'the existing client was not changed by the refused proposal',
  (select full_name = 'Cliente do Vendedor' and phone <> '68999770099' from public.clients where id = (select id from made where label = 'client_v1'));
select public.decide_broker_proposal((select id from made where label = 'p_new'), true, null);
insert into results select 'validation opens the pipeline case',
  exists (select 1 from public.operational_cases where proposal_id = (select id from made where label = 'p_new'))
  and (select status from public.proposal_submissions where proposal_id = (select id from made where label = 'p_new')) = 'validated';
insert into results select 'a decided submission cannot be decided again',
  pg_temp.err(format($q$select public.decide_broker_proposal(%L, false, 'mudei de ideia')$q$, (select id from made where label = 'p_new'))) = 'submission_already_decided';
select public.calculate_proposal_commission((select id from made where label = 'p_new'));
reset role;

select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into results select 'broker sees the refusal reason',
  (select decision_reason from public.proposal_submissions where proposal_id = (select id from made where label = 'p_old')) = 'Cliente já atendido por outro vendedor';
insert into results select 'after refusal the broker still does not see the existing client',
  not exists (select 1 from public.clients where cpf = '52998224725');
insert into results select 'after validation the broker sees only his own commission share',
  (select (r->>'mine')::boolean from (select public.proposal_commission_mine((select id from made where label = 'p_new')) r) x)
  and not exists (select 1 from public.proposal_commission_calcs);
insert into results select 'no document after the decision',
  pg_temp.err(format($q$select public.record_submission_document(%L, 'RG', %L, 'rg.pdf', 'application/pdf', 1, %L)$q$,
    (select id from made where label = 'p_new'), (select org from ids)::text || '/portal/' || (select id from made where label = 'p_new')::text || '/d/rg.pdf', repeat('b', 64))) = 'not_authorized';
reset role;

-- Portal invitation: a seller without login is invited; on acceptance the membership has the 'corretor' role.
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000c0f01', 'novo-corretor@corban-teste.local');
insert into public.commercial_sellers (id, organization_id, name, seller_category, seller_group_id, commission_group_id, is_active)
select '00000000-0000-4000-8000-0000000c0803', organization_id, 'Corretor Convidado', 'pj', seller_group_id, commission_group_id, true
from public.commercial_sellers where id = '00000000-0000-4000-8000-0000000c0801';
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.invite_seller_to_portal('00000000-0000-4000-8000-0000000c0803', 'novo-corretor@corban-teste.local');
reset role;
select * from public.accept_organization_invitations('00000000-0000-4000-8000-0000000c0f01', 'novo-corretor@corban-teste.local');
insert into results select 'portal invitation lands with the corretor role and binds the seller',
  (select r.key from public.organization_memberships m join public.organization_roles r on r.id = m.role_id
   where m.user_id = '00000000-0000-4000-8000-0000000c0f01') = 'corretor'
  and (select user_id from public.commercial_sellers where id = '00000000-0000-4000-8000-0000000c0803') = '00000000-0000-4000-8000-0000000c0f01';
insert into results select 'anon cannot use the portal RPCs',
  not has_function_privilege('anon', 'public.submit_broker_proposal(uuid,text,text,text,text,uuid,numeric,numeric,numeric,integer,text)', 'execute')
  and not has_function_privilege('anon', 'public.decide_broker_proposal(uuid,boolean,text)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 23 then raise exception 'broker portal contract failed'; end if;
end $$;
rollback;
