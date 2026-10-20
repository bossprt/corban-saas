-- Contract test for 20261020163941_crm_followup_v1: tasks per lead (the next contact is the earliest open task), logged
-- contacts, company stages over the three open steps, idle leads for the supervisor, and the "Não perturbe" list (marked,
-- imported, skipped by the queue). A seller only works their own leads. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/crm-followup-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
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

-- Seller 1 and seller 2 each register a lead.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'l1', public.create_sales_lead((select org from ids), 'Lead Tarefa', '68999110001', null, null, null);
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into made select 'l2', public.create_sales_lead((select org from ids), 'Lead Outro', '68999110002', null, null, null);
insert into made select 't9', public.create_lead_task(pg_temp.id('l2'), 'visit', 'Visita do vendedor 2', now() + interval '3 days', null);
reset role;

-- Tasks.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 't1', public.create_lead_task(pg_temp.id('l1'), 'call', 'Ligar depois do pagamento', now() + interval '2 days', null);
insert into made select 't2', public.create_lead_task(pg_temp.id('l1'), 'whatsapp', 'Mandar simulação', now() + interval '1 day', null);
insert into results select 'a task on a new lead puts it in contact', (select status = 'contacted' from public.leads where id = pg_temp.id('l1'));
insert into results select 'the next contact is the earliest open task',
  (select next_contact_at = (select due_at from public.lead_tasks where id = pg_temp.id('t2')) from public.leads where id = pg_temp.id('l1'));
insert into results select 'a seller cannot add a task to another seller''s lead',
  pg_temp.err(format('select public.create_lead_task(%L, %L, %L, now(), null)', pg_temp.id('l2'), 'call', 'x')) like '%lead_forbidden%';
insert into results select 'a seller cannot give a task to someone else',
  pg_temp.err(format('select public.create_lead_task(%L, %L, %L, now(), %L)', pg_temp.id('l1'), 'call', 'x', (select v2 from ids))) like '%invalid_lead_owner%';
select public.finish_lead_task(pg_temp.id('t2'), true, 'interested', 'Gostou da parcela');
insert into results select 'a done task keeps its result and the next contact moves to the next open one',
  (select t.status = 'done' and t.outcome = 'interested' and l.next_contact_at = (select due_at from public.lead_tasks where id = pg_temp.id('t1'))
   from public.lead_tasks t join public.leads l on l.id = t.lead_id where t.id = pg_temp.id('t2'));
insert into results select 'a finished task cannot be finished again',
  pg_temp.err(format('select public.finish_lead_task(%L, true, null, null)', pg_temp.id('t2'))) like '%task_closed%';
insert into made select 'a1', public.log_lead_activity(pg_temp.id('l1'), 'call', 'no_answer', 'Caixa postal');
insert into results select 'a logged contact is a done task with its result',
  (select status = 'done' and kind = 'call' and outcome = 'no_answer' from public.lead_tasks where id = pg_temp.id('a1'));
insert into results select 'the history shows tasks and contacts',
  (select count(*) filter (where event_type = 'task_created') = 2 and count(*) filter (where event_type = 'task_done') = 1
          and count(*) filter (where event_type = 'activity') = 1 from public.lead_events where lead_id = pg_temp.id('l1'));
insert into results select 'the seller does not see the other seller''s tasks',
  exists (select 1 from made where label = 't9') and not exists (select 1 from public.lead_tasks where id = pg_temp.id('t9'));
insert into results select 'a seller cannot finish another seller''s task',
  pg_temp.err(format('select public.finish_lead_task(%L, true, null, null)', pg_temp.id('t9'))) like '%lead_forbidden%';
insert into made select 'a2', public.log_lead_activity(pg_temp.id('l1'), 'whatsapp', 'call_back', null, now() + interval '5 hours', 'Mandar proposta');
insert into results select 'a logged contact can schedule the next one in the same step',
  exists (select 1 from public.lead_tasks where lead_id = pg_temp.id('l1') and status = 'open' and kind = 'whatsapp' and title = 'Mandar proposta');
insert into results select 'tasks cannot be written directly',
  pg_temp.err(format('insert into public.lead_tasks (organization_id, lead_id, kind, title, due_at, assigned_to, created_by) values (%L, %L, %L, %L, now(), %L, %L)',
    (select org from ids), pg_temp.id('l1'), 'call', 'x', (select v1 from ids), (select v1 from ids))) like '%permission denied%';
reset role;

-- Stages of the company: only a supervisor creates them; a lead moved there changes its base step.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot create stages',
  pg_temp.err(format('select public.save_sales_lead_stage(%L, null, %L, %L, 1, true)', (select org from ids), 'Aguardando documento', 'negotiating')) like '%not_authorized%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 's1', public.save_sales_lead_stage((select org from ids), null, 'Aguardando documento', 'negotiating', 1, true);
insert into made select 's2', public.save_sales_lead_stage((select org from ids), null, 'Simulado', 'negotiating', 2, true);
insert into results select 'stage names are unique in the company',
  pg_temp.err(format('select public.save_sales_lead_stage(%L, null, %L, %L, 3, true)', (select org from ids), ' simulado ', 'contacted')) like '%stage_name_taken%';
reset role;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
select public.move_lead_to_stage(pg_temp.id('l1'), pg_temp.id('s1'));
insert into results select 'moving to a company stage sets its base step', (select status = 'negotiating' and stage_id = pg_temp.id('s1') from public.leads where id = pg_temp.id('l1'));
select public.set_lead_status(pg_temp.id('l1'), 'contacted', null);
insert into results select 'leaving the base step clears the company stage', (select status = 'contacted' and stage_id is null from public.leads where id = pg_temp.id('l1'));
select public.move_lead_to_stage(pg_temp.id('l1'), pg_temp.id('s2'));
insert into results select 'a seller cannot move another seller''s lead',
  pg_temp.err(format('select public.move_lead_to_stage(%L, %L)', pg_temp.id('l2'), pg_temp.id('s1'))) like '%lead_forbidden%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.save_sales_lead_stage((select org from ids), pg_temp.id('s2'), 'Simulado', 'negotiating', 2, false);
insert into results select 'deactivating a stage sends its leads to the step''s first column', (select stage_id is null from public.leads where id = pg_temp.id('l1'));
reset role;

-- Idle leads and back to the queue.
set local session_replication_role = replica;
update public.leads set stage_changed_at = now() - interval '10 days', updated_at = now() - interval '10 days', assigned_at = now() - interval '10 days' where id = pg_temp.id('l2');
update public.lead_events set created_at = now() - interval '10 days' where lead_id = pg_temp.id('l2');
update public.lead_tasks set due_at = now() - interval '9 days', created_at = now() - interval '10 days', updated_at = now() - interval '10 days' where lead_id = pg_temp.id('l2');
set local session_replication_role = origin;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot list idle leads', not exists (select 1 from public.idle_leads((select org from ids), 3));
insert into results select 'a seller cannot send leads back to the queue',
  pg_temp.err(format('select public.release_leads(%L, array[%L]::uuid[])', (select org from ids), pg_temp.id('l2'))) like '%not_authorized%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'passing a lead to another seller', public.assign_leads((select org from ids), (select v1 from ids), array[pg_temp.id('l2')], null, null) = 1;
insert into results select 'its open tasks go to the new seller', (select assigned_to = (select v1 from ids) from public.lead_tasks where id = pg_temp.id('t9'));
select public.assign_leads((select org from ids), (select v2 from ids), array[pg_temp.id('l2')], null, null);
reset role;
set local session_replication_role = replica;
update public.leads set updated_at = now() - interval '10 days', assigned_at = now() - interval '10 days' where id = pg_temp.id('l2');
update public.lead_events set created_at = now() - interval '10 days' where lead_id = pg_temp.id('l2');
update public.lead_tasks set updated_at = now() - interval '10 days' where lead_id = pg_temp.id('l2');
set local session_replication_role = origin;
set local role authenticated;
insert into results select 'the supervisor sees the lead idle for 10 days, not the busy one',
  exists (select 1 from public.idle_leads((select org from ids), 3) where lead_id = pg_temp.id('l2'))
  and not exists (select 1 from public.idle_leads((select org from ids), 3) where lead_id = pg_temp.id('l1'));
insert into results select 'one lead released', public.release_leads((select org from ids), array[pg_temp.id('l2')]) = 1;
insert into results select 'released leads go back to the queue (no owner)', (select owner_user_id is null from public.leads where id = pg_temp.id('l2'));
insert into results select 'released leads have no open task', not exists (select 1 from public.lead_tasks where lead_id = pg_temp.id('l2') and status = 'open');
reset role;

-- "Não perturbe". Leads without a campaign wait in the company queue (fixture: the company distributes by queue).
insert into public.organization_lead_settings (organization_id, distribution) values ((select org from ids), 'queue')
on conflict (organization_id) do update set distribution = 'queue';
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller marks the lead''s phone', public.mark_phone_dnd((select org from ids), '(68) 99911-0001', 'Pediu para não ligar', pg_temp.id('l1'));
insert into results select 'the phone is stored normalized and the lead history records it',
  exists (select 1 from public.do_not_disturb_phones where organization_id = (select org from ids) and phone = '5568999110001' and removed_at is null)
  and exists (select 1 from public.lead_events where lead_id = pg_temp.id('l1') and event_type = 'dnd_marked');
insert into results select 'the board finds the marked phone', (select array_agg(x) from public.dnd_phones_in((select org from ids), array['68999110001', '68999110002']) x) = array['5568999110001'];
insert into results select 'a seller cannot remove a phone from the list',
  pg_temp.err(format('select public.unmark_phone_dnd(%L, %L)', (select org from ids), '68999110001')) like '%not_authorized%';
insert into results select 'a seller cannot import a list',
  pg_temp.err(format('select public.import_dnd_phones(%L, %L, array[%L])', (select org from ids), 'lista.csv', '68999110009')) like '%not_authorized%';
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'before the list, the released lead is in the queue',
  exists (select 1 from private.caller_queue_leads((select org from ids), null) q where q = pg_temp.id('l2'));
insert into results select 'a list import counts added, already there and invalid',
  public.import_dnd_phones((select org from ids), 'banco.csv', array['68999110002', '5568999110001', '123', '(68) 99911-0002']) = '{"added": 1, "already": 1, "invalid": 1}'::jsonb;
insert into results select 'a lead whose phone is on the list leaves the queue',
  not exists (select 1 from private.caller_queue_leads((select org from ids), null) q where q = pg_temp.id('l2'));
insert into results select 'the supervisor removes a phone', public.unmark_phone_dnd((select org from ids), '68999110002');
insert into results select 'a removed phone is kept, marked removed',
  exists (select 1 from public.do_not_disturb_phones where phone = '5568999110002' and removed_at is not null);
reset role;

-- Closing the lead cancels its open tasks.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
select public.set_lead_status(pg_temp.id('l1'), 'lost', 'Sem margem');
insert into results select 'a lost lead has no open task and no next contact',
  not exists (select 1 from public.lead_tasks where lead_id = pg_temp.id('l1') and status = 'open')
  and (select next_contact_at is null from public.leads where id = pg_temp.id('l1'));
reset role;

insert into results select 'anon has nothing on the new tables and functions',
  not has_table_privilege('anon', 'public.lead_tasks', 'select') and not has_table_privilege('anon', 'public.do_not_disturb_phones', 'select')
  and not has_function_privilege('anon', 'public.import_dnd_phones(uuid, text, text[])', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'crm follow-up contract failed'; end if;
end $$;
rollback;
