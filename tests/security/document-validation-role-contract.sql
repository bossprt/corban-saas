-- Contract test for 20261107043958_document_validation_role_guard_v1: only Supervisor, Gerente or Administrador decide a
-- document of the contract checklist ("Validar", recusar, dispensar), also when the API is called directly. A seller
-- who sees the contract attaches a file but cannot validate it, cannot create a checklist item already validated or
-- waived, and cannot rewrite the reason of a waiver; a supervisor and an admin validate. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/document-validation-role-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as supervisor_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user,
       (select id from public.document_types where code = 'rg') as rg;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- A contract the seller can see (so a refusal below is the role rule, not the visibility rule): one of the company's
-- contracts, written by the seller for this test.
insert into made select 'proposal', id from public.proposals_v2 where organization_id = (select org from ids) order by created_at limit 1;
set local session_replication_role = replica; -- test fixture only: skip the proposal identity guard for this one write
update public.proposals_v2 set created_by = (select seller_user from ids) where id = (select id from made where label = 'proposal');
-- The seller is in the supervisor's team, so the supervisor sees the seller's contract.
update public.organization_memberships set team_leader_user_id = (select supervisor_user from ids)
where organization_id = (select org from ids) and user_id = (select seller_user from ids);
set local session_replication_role = origin;
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'the seller sees the contract', exists (select 1 from public.proposals_v2 where id = (select id from made where label = 'proposal'));
reset role;

-- Three checklist items with an attached file of the right type (written by the system, as the checklist RPC does).
insert into made select 'customer', customer_id from public.proposals_v2 where id = (select id from made where label = 'proposal');
do $$
declare v_org uuid := (select org from ids); v_rg uuid := (select rg from ids);
  v_prop uuid := (select id from made where label = 'proposal'); v_cust uuid := (select id from made where label = 'customer');
  v_req uuid; v_doc uuid; i int;
begin
  for i in 1..3 loop
    insert into public.proposal_document_requirements (organization_id, proposal_id, document_type_id, label_snapshot, required_snapshot)
    values (v_org, v_prop, v_rg, 'RG teste ' || i, true) returning id into v_req;
    insert into public.customer_documents (organization_id, customer_id, document_type_id, storage_bucket, storage_path, original_file_name, sha256)
    values (v_org, v_cust, v_rg, 'customer-documents', 'contract-test/doc-validation-' || gen_random_uuid(), 'rg.pdf', md5(gen_random_uuid()::text))
    returning id into v_doc;
    insert into public.proposal_document_links (organization_id, requirement_id, customer_document_id) values (v_org, v_req, v_doc);
    insert into made values ('req' || i, v_req);
  end loop;
end $$;

-- Seller: attaches (allowed), but cannot decide.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'the seller sees the checklist items', (select count(*) = 3 from public.proposal_document_requirements where id in (select id from made where label like 'req%'));
insert into results select 'the seller attaches a file to an item',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L where id in (%L, %L, %L)', 'attached',
    (select id from made where label = 'req1'), (select id from made where label = 'req2'), (select id from made where label = 'req3'))) = 'ok';
insert into results select 'the seller cannot validate a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L where id = %L', 'validated', (select id from made where label = 'req1'))) like '%requires_privileged_role%';
insert into results select 'the seller cannot reject a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L where id = %L', 'rejected', (select id from made where label = 'req1'))) like '%requires_privileged_role%';
insert into results select 'the seller cannot waive a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L, exception_reason = %L, exception_approved_by = %L, exception_approved_at = now() where id = %L',
    'waived', 'sem doc', (select seller_user from ids), (select id from made where label = 'req1'))) like '%requires_privileged_role%';
insert into results select 'the seller cannot create a checklist item already validated',
  pg_temp.err(format('insert into public.proposal_document_requirements (organization_id, proposal_id, document_type_id, label_snapshot, required_snapshot, status) values (%L, %L, %L, %L, true, %L)',
    (select org from ids), (select id from made where label = 'proposal'), (select rg from ids), 'RG forjado', 'validated')) like '%document_requirement_must_start_missing%';
insert into results select 'the seller cannot create a checklist item already waived',
  pg_temp.err(format('insert into public.proposal_document_requirements (organization_id, proposal_id, document_type_id, label_snapshot, required_snapshot, status, exception_reason, exception_approved_by, exception_approved_at) values (%L, %L, %L, %L, true, %L, %L, %L, now())',
    (select org from ids), (select id from made where label = 'proposal'), (select rg from ids), 'RG forjado', 'waived', 'sem doc', (select seller_user from ids))) like '%document_requirement_must_start_missing%';
reset role;
insert into results select 'the item the seller tried to validate is still attached',
  (select status = 'attached' from public.proposal_document_requirements where id = (select id from made where label = 'req1'));

-- Supervisor and admin validate; the supervisor waives one.
select pg_temp.act_as((select supervisor_user from ids));
set local role authenticated;
insert into results select 'the supervisor sees the checklist items', (select count(*) = 3 from public.proposal_document_requirements where id in (select id from made where label like 'req%'));
insert into results select 'the supervisor validates a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L where id = %L', 'validated', (select id from made where label = 'req1'))) = 'ok';
insert into results select 'the supervisor waives a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L, exception_reason = %L, exception_approved_by = %L, exception_approved_at = now() where id = %L',
    'waived', 'Cliente sem RG', (select supervisor_user from ids), (select id from made where label = 'req3'))) = 'ok';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the admin validates a document',
  pg_temp.err(format('update public.proposal_document_requirements set status = %L where id = %L', 'validated', (select id from made where label = 'req2'))) = 'ok';
reset role;

-- Seller cannot rewrite who waived it or why.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'the seller cannot rewrite the reason of a waiver',
  pg_temp.err(format('update public.proposal_document_requirements set exception_reason = %L where id = %L', 'outro motivo', (select id from made where label = 'req3'))) like '%document_exception_is_immutable%';
reset role;

insert into results select 'validated and waived items stay as decided',
  (select count(*) = 2 from public.proposal_document_requirements where id in (select id from made where label in ('req1', 'req2')) and status = 'validated')
  and (select status = 'waived' and exception_reason = 'Cliente sem RG' from public.proposal_document_requirements where id = (select id from made where label = 'req3'));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'document validation role contract failed'; end if;
end $$;
rollback;
