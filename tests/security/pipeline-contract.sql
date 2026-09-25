-- Contract test for 20260924142925_pipeline_direct_proposals_v1. Local test company (seed with commercial structure)
-- and users admin / supervisor / vendedor / vendedor2 @corban-teste.local. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/pipeline-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0301'::uuid as tv,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated, service_role;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated, service_role;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated, service_role;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- Seller 1: client and a proposal already digitized (with ADE).
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Esteira', '68999770001', null, 'manual') u;
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), null, 10000, 9500, 250.00, 84, 'ADE-100200', 'submitted') d;
insert into results select 'direct proposal is created', (select id from made where label = 'p1') is not null;
insert into results select 'same bank + ADE returns the same proposal',
  (select d.proposal_id = (select id from made where label = 'p1') and d.duplicate from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), null, 10000, 9500, 250.00, 84, 'ADE-100200', 'submitted') d);
do $$ begin
  begin
    perform public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), null, 5000, null, null, null, null, 'submitted');
    insert into results values ('already digitized requires the ADE', false);
  exception when others then insert into results values ('already digitized requires the ADE', sqlerrm = 'ade_required'); end;
  begin
    perform public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), null, -1, null, null, null, null, 'digitization_queue');
    insert into results values ('negative amount is refused', false);
  exception when others then insert into results values ('negative amount is refused', sqlerrm = 'invalid_amount'); end;
  begin
    perform public.move_operational_case((select c.id from public.operational_cases c where c.proposal_id = (select id from made where label = 'p1')), 'paid', 'vi no portal', null);
    insert into results values ('seller without esteira.edit cannot move', false);
  exception when others then insert into results values ('seller without esteira.edit cannot move', sqlerrm = 'not_authorized'); end;
end $$;
insert into results select 'proposal starts in analysis', canonical_state = 'submitted' from public.operational_cases where proposal_id = (select id from made where label = 'p1');
reset role;

-- Seller 2 cannot see seller 1's proposal or its case.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'other seller does not see the proposal', not exists (select 1 from public.proposals_v2 where id = (select id from made where label = 'p1'));
insert into results select 'other seller does not see the case', not exists (select 1 from public.operational_cases where proposal_id = (select id from made where label = 'p1'));
reset role;

-- Administrator runs the pipeline.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'case', id from public.operational_cases where proposal_id = (select id from made where label = 'p1');
do $$ begin
  begin
    perform public.move_operational_case((select id from made where label = 'case'), 'pending_external', 'falta comprovante', null);
    insert into results values ('pendency requires a due date', false);
  exception when others then insert into results values ('pendency requires a due date', sqlerrm = 'pendency_due_required'); end;
end $$;
select public.move_operational_case((select id from made where label = 'case'), 'pending_external', 'Falta comprovante de residência', now() + interval '2 days');
insert into results select 'pendency keeps reason and due date', canonical_state = 'pending_external' and pendency_reason like 'Falta%' and pendency_due_at > now() from public.operational_cases where id = (select id from made where label = 'case');
select public.move_operational_case((select id from made where label = 'case'), 'submitted', null, null);
insert into results select 'solved pendency returns to analysis', canonical_state = 'submitted' and pendency_reason is null from public.operational_cases where id = (select id from made where label = 'case');
do $$ begin
  begin
    perform public.move_operational_case((select id from made where label = 'case'), 'paid', null, null);
    insert into results values ('manual paid requires a note', false);
  exception when others then insert into results values ('manual paid requires a note', sqlerrm = 'note_required'); end;
end $$;
select public.move_operational_case((select id from made where label = 'case'), 'paid', 'Pago no portal do Banco Teste', null);
insert into results select 'case and proposal are paid', (select canonical_state = 'paid' from public.operational_cases where id = (select id from made where label = 'case'))
  and (select status = 'paid' from public.proposals_v2 where id = (select id from made where label = 'p1'));
insert into results select 'manual payment evidence is recorded', exists (select 1 from public.proposal_status_evidence where proposal_id = (select id from made where label = 'p1') and source = 'manual' and note like 'Pago no portal%');

-- Goals: target for seller 1, progress from the paid proposal (released amount 9500.00).
select public.set_seller_goal((select org from ids), (select v1 from ids), current_date, 50000);
insert into results select 'goal progress counts the paid released amount', target_amount = 50000 and paid_amount = 9500.00 and paid_count = 1
  from public.goal_progress((select org from ids), current_date) where user_id = (select v1 from ids);

-- Distribution: round robin to seller 2.
select public.set_lead_distribution((select org from ids), 'round_robin');
select public.set_member_receives_leads((select id from public.organization_memberships where user_id = (select v2 from ids)), true);
insert into made select 'key', null;
create temp table apikey as select api_key from public.create_api_key((select org from ids), 'Contrato F3', array['leads.write']);
grant select on apikey to service_role;
reset role;

set local role service_role;
insert into made select 'lead_rr', (public.api_ingest_lead_distributed((select api_key from apikey), '{"full_name":"Lead Rodizio","phone":"68977770001"}'::jsonb)->>'id')::uuid;
reset role;
insert into results select 'round robin gives the lead to the eligible seller', owner_user_id = (select v2 from ids) and assigned_at is not null from public.leads where id = (select id from made where label = 'lead_rr');

-- Queue: an unassigned lead is visible to a seller and can be claimed once.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_lead_distribution((select org from ids), 'queue');
reset role;
set local role service_role;
insert into made select 'lead_q', (public.api_ingest_lead_distributed((select api_key from apikey), '{"full_name":"Lead Fila","phone":"68977770002"}'::jsonb)->>'id')::uuid;
reset role;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'queue lead is visible to the seller', exists (select 1 from public.leads where id = (select id from made where label = 'lead_q'));
select public.claim_lead((select id from made where label = 'lead_q'));
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
do $$ begin
  begin
    perform public.claim_lead((select id from made where label = 'lead_q'));
    insert into results values ('a claimed lead cannot be taken again', false);
  exception when others then insert into results values ('a claimed lead cannot be taken again', true); end;
end $$;
insert into results select 'claimed lead leaves the other sellers view', not exists (select 1 from public.leads where id = (select id from made where label = 'lead_q'));
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'pipeline contract failed'; end if;
end $$;

rollback;
