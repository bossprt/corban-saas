-- CRM phase 1 (owner, 20/10/2026: "profissionalizar esse CRM"): follow-up that does not get lost.
--   1. Tasks per lead: what to do (call, WhatsApp, visit, e-mail, other), when, for whom; done with a result. A contact
--      already made is logged as a done task ("Registrar contato"). The lead's next contact is its earliest open task.
--   2. Stages of the company: the open part of the board (Novo, Em contato, Negociando) gets the company's own columns,
--      each tied to one of those three base steps. Proposta, Ganho and Perdido stay fixed (they follow the proposal).
--   3. Idle leads: open leads with an owner and no movement for N days, for a supervisor to pass on or send back to the queue.
--   4. "Não perturbe": the company's list of phones that asked not to be contacted, marked by hand or imported from a
--      list (the banks send them). The system warns; it never blocks (owner: warn, the seller decides). Those leads leave
--      the queue. A Lemit lookup can feed the same list later.

-- 1. Tasks ------------------------------------------------------------------------------------------------------------
create table public.lead_tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  lead_id uuid not null references public.leads(id) on delete cascade,
  kind text not null check (kind in ('call', 'whatsapp', 'visit', 'email', 'other')),
  title text not null check (length(btrim(title)) between 1 and 200),
  due_at timestamptz not null,
  assigned_to uuid not null references auth.users(id),
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  outcome text check (outcome in ('answered', 'no_answer', 'wrong_number', 'call_back', 'interested', 'not_interested', 'sold', 'other')),
  result_note text check (result_note is null or length(result_note) <= 1000),
  done_at timestamptz,
  done_by uuid references auth.users(id),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lead_tasks_done_consistency check ((status = 'done') = (done_at is not null))
);
create index lead_tasks_lead_idx on public.lead_tasks (lead_id, status, due_at);
create index lead_tasks_assignee_open_idx on public.lead_tasks (assigned_to, due_at) where status = 'open';
create index lead_tasks_org_idx on public.lead_tasks (organization_id, status, due_at);
alter table public.lead_tasks enable row level security;
revoke all on table public.lead_tasks from anon, authenticated;
grant select on table public.lead_tasks to authenticated;
-- A task is seen by whoever sees its lead (the lead's own scope rules apply inside the subquery).
create policy lead_tasks_select on public.lead_tasks for select to authenticated
  using (public.has_permission(organization_id, 'leads.view') and exists (select 1 from public.leads l where l.id = lead_id));

alter table public.lead_events drop constraint lead_events_event_type_check;
alter table public.lead_events add constraint lead_events_event_type_check check (event_type in
  ('created', 'imported', 'status_changed', 'owner_changed', 'converted', 'client_linked', 'note', 'next_contact',
   'proposal_linked', 'won', 'reactivated', 'task_created', 'task_done', 'task_cancelled', 'activity', 'stage_moved',
   'dnd_marked', 'released'));

-- The lead's next contact is its earliest open task.
create or replace function private.sync_lead_next_contact(p_lead uuid)
returns void language sql security definer set search_path = '' as $$
  update public.leads l
  set next_contact_at = (select min(t.due_at) from public.lead_tasks t where t.lead_id = l.id and t.status = 'open')
  where l.id = p_lead
$$;
revoke all on function private.sync_lead_next_contact(uuid) from public, anon, authenticated;

-- First contact: a new lead with a task or a logged contact is "Em contato" (as the old "Marcar retorno" did).
create or replace function private.lead_touched(p_lead uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare l public.leads%rowtype;
begin
  select * into l from public.leads where id = p_lead;
  if l.status = 'new' then
    update public.leads set status = 'contacted', stage_changed_at = now(), updated_at = now() where id = l.id;
    insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id)
    values (l.organization_id, l.id, 'status_changed', 'new', 'contacted', auth.uid());
  else
    update public.leads set updated_at = now() where id = l.id;
  end if;
end $$;
revoke all on function private.lead_touched(uuid) from public, anon, authenticated;

-- Existing returns become open tasks, so nothing scheduled is lost.
insert into public.lead_tasks (organization_id, lead_id, kind, title, due_at, assigned_to, created_by, created_at)
select l.organization_id, l.id, 'call', 'Retorno', l.next_contact_at, l.owner_user_id, l.owner_user_id, now()
from public.leads l
where l.next_contact_at is not null and l.status not in ('won', 'lost') and l.owner_user_id is not null;
-- A queue lead (no owner) keeps no return: whoever takes it schedules the next one.
update public.leads set next_contact_at = null where owner_user_id is null and next_contact_at is not null;

-- New task on a lead the caller works. Without p_assignee it is the lead's owner (or the caller); a supervisor may
-- give it to another seller who can own leads.
create or replace function public.create_lead_task(p_lead uuid, p_kind text, p_title text, p_due_at timestamptz, p_assignee uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare l public.leads%rowtype; v_user uuid := auth.uid(); v_to uuid; v_id uuid;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or v_user is null or not private.lead_workable(l.organization_id, l.owner_user_id, l.created_by) then raise exception 'lead_forbidden'; end if;
  if l.status in ('won', 'lost') then raise exception 'lead_closed'; end if;
  if p_kind is null or p_kind not in ('call', 'whatsapp', 'visit', 'email', 'other') then raise exception 'invalid_task'; end if;
  if p_due_at is null or length(btrim(coalesce(p_title, ''))) not between 1 and 200 then raise exception 'invalid_task'; end if;
  v_to := coalesce(p_assignee, l.owner_user_id, v_user);
  if v_to <> coalesce(l.owner_user_id, v_user) then
    if not public.has_permission(l.organization_id, 'leads.approve') or not private.can_own_leads(l.organization_id, v_to) then raise exception 'invalid_lead_owner'; end if;
  end if;
  insert into public.lead_tasks (organization_id, lead_id, kind, title, due_at, assigned_to, created_by)
  values (l.organization_id, l.id, p_kind, btrim(p_title), p_due_at, v_to, v_user)
  returning id into v_id;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (l.organization_id, l.id, 'task_created', v_user, jsonb_build_object('task_id', v_id, 'kind', p_kind, 'title', btrim(p_title), 'due_at', p_due_at));
  perform private.sync_lead_next_contact(l.id);
  perform private.lead_touched(l.id);
  return v_id;
end $$;

-- Done (with the result) or cancelled, by whoever works the lead (its owner, or a supervisor over that owner).
create or replace function public.finish_lead_task(p_task uuid, p_done boolean, p_outcome text default null, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare t public.lead_tasks%rowtype; l public.leads%rowtype; v_user uuid := auth.uid();
begin
  select * into t from public.lead_tasks where id = p_task for update;
  if t.id is null or v_user is null then raise exception 'lead_forbidden'; end if;
  select * into l from public.leads where id = t.lead_id for update;
  if not private.lead_workable(l.organization_id, l.owner_user_id, l.created_by) then raise exception 'lead_forbidden'; end if;
  if t.status <> 'open' then raise exception 'task_closed'; end if;
  if p_outcome is not null and p_outcome not in ('answered', 'no_answer', 'wrong_number', 'call_back', 'interested', 'not_interested', 'sold', 'other') then raise exception 'invalid_task'; end if;
  if length(coalesce(p_note, '')) > 1000 then raise exception 'invalid_task'; end if;
  update public.lead_tasks
  set status = case when p_done then 'done' else 'cancelled' end, outcome = case when p_done then p_outcome end,
      result_note = nullif(btrim(coalesce(p_note, '')), ''), done_at = case when p_done then now() end, done_by = v_user, updated_at = now()
  where id = t.id;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (t.organization_id, t.lead_id, case when p_done then 'task_done' else 'task_cancelled' end, v_user,
          jsonb_build_object('task_id', t.id, 'kind', t.kind, 'title', t.title, 'outcome', p_outcome, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  perform private.sync_lead_next_contact(t.lead_id);
  update public.leads set updated_at = now() where id = t.lead_id;
end $$;

-- A contact already made (call, WhatsApp, visit...): logged as a done task with its result.
create or replace function public.log_lead_activity(p_lead uuid, p_kind text, p_outcome text, p_note text default null,
                                                     p_next_at timestamptz default null, p_next_title text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare l public.leads%rowtype; v_user uuid := auth.uid(); v_id uuid;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null or v_user is null or not private.lead_workable(l.organization_id, l.owner_user_id, l.created_by) then raise exception 'lead_forbidden'; end if;
  if p_kind is null or p_kind not in ('call', 'whatsapp', 'visit', 'email', 'other') then raise exception 'invalid_task'; end if;
  if p_outcome is null or p_outcome not in ('answered', 'no_answer', 'wrong_number', 'call_back', 'interested', 'not_interested', 'sold', 'other') then raise exception 'invalid_task'; end if;
  if length(coalesce(p_note, '')) > 1000 then raise exception 'invalid_task'; end if;
  insert into public.lead_tasks (organization_id, lead_id, kind, title, due_at, assigned_to, status, outcome, result_note, done_at, done_by, created_by)
  values (l.organization_id, l.id, p_kind, 'Contato registrado', now(), v_user, 'done', p_outcome, nullif(btrim(coalesce(p_note, '')), ''), now(), v_user, v_user)
  returning id into v_id;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (l.organization_id, l.id, 'activity', v_user, jsonb_build_object('task_id', v_id, 'kind', p_kind, 'outcome', p_outcome, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  if l.status not in ('won', 'lost') then perform private.lead_touched(l.id); end if;
  -- "Próximo contato" in the same form: a new task, same kind.
  if p_next_at is not null then
    perform public.create_lead_task(l.id, p_kind, coalesce(nullif(btrim(coalesce(p_next_title, '')), ''), 'Retorno'), p_next_at, null);
  end if;
  return v_id;
end $$;

-- Won or lost: the lead's open tasks are cancelled (nothing left to do).
create or replace function private.leads_close_tasks()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('won', 'lost') and old.status is distinct from new.status then
    update public.lead_tasks set status = 'cancelled', done_by = null, updated_at = now(), result_note = coalesce(result_note, 'Lead ' || case when new.status = 'won' then 'ganho' else 'perdido' end)
    where lead_id = new.id and status = 'open';
    new.next_contact_at := null;
  end if;
  return new;
end $$;
revoke all on function private.leads_close_tasks() from public, anon, authenticated;
create trigger leads_20_close_tasks before update of status on public.leads
  for each row execute function private.leads_close_tasks();

-- The old "Marcar retorno" now makes a task (a call), so every return is a task. An empty date does nothing: a return
-- is removed by cancelling its task. (The lead_write 'next_contact' operation has no caller left.)
create or replace function public.set_lead_next_contact(p_lead_id uuid, p_at timestamptz)
returns uuid language plpgsql security invoker set search_path = '' as $$
begin
  if p_at is not null then perform public.create_lead_task(p_lead_id, 'call', 'Retorno', p_at, null); end if;
  return p_lead_id;
end $$;

-- 2. Stages of the company --------------------------------------------------------------------------------------------
create table public.sales_lead_stages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (length(btrim(name)) between 1 and 40),
  base_status text not null check (base_status in ('new', 'contacted', 'negotiating')),
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create unique index sales_lead_stages_name_uidx on public.sales_lead_stages (organization_id, lower(btrim(name))) where is_active;
alter table public.sales_lead_stages enable row level security;
revoke all on table public.sales_lead_stages from anon, authenticated;
grant select on table public.sales_lead_stages to authenticated;
create policy sales_lead_stages_select on public.sales_lead_stages for select to authenticated
  using (public.has_permission(organization_id, 'leads.view'));

alter table public.leads add column stage_id uuid;
alter table public.leads add constraint leads_stage_fk foreign key (organization_id, stage_id) references public.sales_lead_stages (organization_id, id);

-- A company stage belongs to one base step: when the lead leaves that step (by hand, by the proposal, by a task), the
-- company stage no longer applies and the lead shows in the first column of its new step.
create or replace function private.leads_stage_follows_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.stage_id is not null and (tg_op = 'INSERT' or new.status is distinct from old.status or new.stage_id is distinct from old.stage_id) then
    if not exists (select 1 from public.sales_lead_stages s where s.id = new.stage_id and s.organization_id = new.organization_id
                   and s.base_status = new.status and s.is_active) then
      new.stage_id := null;
    end if;
  end if;
  return new;
end $$;
revoke all on function private.leads_stage_follows_status() from public, anon, authenticated;
create trigger leads_10_stage_follows_status before insert or update of status, stage_id on public.leads
  for each row execute function private.leads_stage_follows_status();

-- Create, rename, reorder or deactivate a company stage (supervisor). Deactivating moves its leads to the step's first column.
create or replace function public.save_sales_lead_stage(p_org uuid, p_id uuid, p_name text, p_base_status text, p_sort_order int, p_active boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := p_id; v_user uuid := auth.uid();
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  if p_base_status not in ('new', 'contacted', 'negotiating') or length(btrim(coalesce(p_name, ''))) not between 1 and 40 then raise exception 'invalid_stage'; end if;
  begin
    if v_id is null then
      insert into public.sales_lead_stages (organization_id, name, base_status, sort_order, is_active, created_by)
      values (p_org, btrim(p_name), p_base_status, coalesce(p_sort_order, 0), coalesce(p_active, true), v_user) returning id into v_id;
    else
      update public.sales_lead_stages set name = btrim(p_name), base_status = p_base_status, sort_order = coalesce(p_sort_order, sort_order),
             is_active = coalesce(p_active, is_active), updated_at = now()
      where organization_id = p_org and id = v_id;
      if not found then raise exception 'invalid_stage'; end if;
      -- Leads whose stage no longer fits (deactivated or moved to another step) fall back to the step's first column.
      update public.leads set stage_id = null, updated_at = now()
      where organization_id = p_org and stage_id = v_id and (not coalesce(p_active, true) or status <> p_base_status);
    end if;
  exception when unique_violation then raise exception 'stage_name_taken';
  end;
  return v_id;
end $$;

-- Move a lead to a company stage (board drag or the lead's stage buttons). Same rules as the base step change.
create or replace function public.move_lead_to_stage(p_lead uuid, p_stage uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare l public.leads%rowtype; s public.sales_lead_stages%rowtype; v_user uuid := auth.uid();
begin
  select * into l from public.leads where id = p_lead;
  select * into s from public.sales_lead_stages where id = p_stage and organization_id = l.organization_id and is_active;
  if l.id is null or s.id is null or v_user is null then raise exception 'lead_forbidden'; end if;
  if l.status <> s.base_status then
    perform public.set_lead_status(p_lead, s.base_status, null);
  elsif not private.lead_workable(l.organization_id, l.owner_user_id, l.created_by) then
    raise exception 'lead_forbidden';
  end if;
  update public.leads set stage_id = s.id, stage_changed_at = now(), updated_at = now() where id = p_lead;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (l.organization_id, l.id, 'stage_moved', v_user, jsonb_build_object('stage_id', s.id, 'stage', s.name));
end $$;

-- 3. Idle leads -------------------------------------------------------------------------------------------------------
-- Open leads with an owner whose last movement (stage, history, task) is older than p_days. Supervisor only.
create or replace function public.idle_leads(p_org uuid, p_days int)
returns table(lead_id uuid, full_name text, status text, owner_user_id uuid, campaign_id uuid, last_activity_at timestamptz, open_tasks int)
language sql stable security definer set search_path = '' as $$
  select l.id, l.full_name, l.status, l.owner_user_id, l.campaign_id, x.last_at,
         (select count(*)::int from public.lead_tasks t where t.lead_id = l.id and t.status = 'open')
  from public.leads l
  cross join lateral (select greatest(l.stage_changed_at, l.assigned_at, l.updated_at,
                                      (select max(e.created_at) from public.lead_events e where e.lead_id = l.id),
                                      (select max(coalesce(t.done_at, t.updated_at)) from public.lead_tasks t where t.lead_id = l.id)) as last_at) x
  where (select auth.uid()) is not null and public.has_permission(p_org, 'leads.approve')
    and l.organization_id = p_org and l.owner_user_id is not null and l.status in ('new', 'contacted', 'negotiating')
    and private.can_see_owner(p_org, l.owner_user_id)
    and x.last_at < now() - make_interval(days => greatest(coalesce(p_days, 3), 1))
    and not exists (select 1 from public.lead_tasks t where t.lead_id = l.id and t.status = 'open' and t.due_at >= now())
  order by x.last_at
  limit 1000
$$;

-- Send leads back to the queue (no owner): their open tasks are cancelled.
create or replace function public.release_leads(p_org uuid, p_lead_ids uuid[])
returns int language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_ids uuid[]; n int;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  if p_lead_ids is null or cardinality(p_lead_ids) > 500 then raise exception 'too_many_leads'; end if;
  select array_agg(l.id) into v_ids from public.leads l
  where l.organization_id = p_org and l.id = any (p_lead_ids) and l.owner_user_id is not null and l.status in ('new', 'contacted', 'negotiating')
    and private.can_see_owner(p_org, l.owner_user_id);
  if v_ids is null then return 0; end if;
  update public.lead_tasks set status = 'cancelled', result_note = coalesce(result_note, 'Lead devolvido para a fila'), done_by = v_user, updated_at = now()
  where lead_id = any (v_ids) and status = 'open';
  update public.leads set owner_user_id = null, assigned_at = null, next_contact_at = null, updated_at = now() where id = any (v_ids);
  get diagnostics n = row_count;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  select p_org, x, 'released', v_user, '{}'::jsonb from unnest(v_ids) x;
  return n;
end $$;

-- 4. "Não perturbe" ---------------------------------------------------------------------------------------------------
create table public.do_not_disturb_phones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  phone text not null check (phone ~ '^55[0-9]{10,11}$'),
  source text not null check (source in ('manual', 'import', 'lemit')),
  note text check (note is null or length(note) <= 300),
  file_name text check (file_name is null or length(file_name) <= 255),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid references auth.users(id)
);
create unique index do_not_disturb_phones_active_uidx on public.do_not_disturb_phones (organization_id, phone) where removed_at is null;
alter table public.do_not_disturb_phones enable row level security;
revoke all on table public.do_not_disturb_phones from anon, authenticated;
grant select on table public.do_not_disturb_phones to authenticated;
create policy do_not_disturb_phones_select on public.do_not_disturb_phones for select to authenticated
  using (public.has_permission(organization_id, 'leads.view'));

create or replace function private.phone_is_dnd(p_org uuid, p_phone text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_phone is not null and exists (select 1 from public.do_not_disturb_phones d
                                         where d.organization_id = p_org and d.phone = private.normalize_phone(p_phone) and d.removed_at is null)
$$;
revoke all on function private.phone_is_dnd(uuid, text) from public, anon;
grant execute on function private.phone_is_dnd(uuid, text) to authenticated;

-- Mark one phone (any seller who works leads; usually from the lead: "o cliente pediu para não ligar").
create or replace function public.mark_phone_dnd(p_org uuid, p_phone text, p_note text default null, p_lead uuid default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_phone text := private.normalize_phone(p_phone); n int;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.edit') then raise exception 'not_authorized'; end if;
  if v_phone is null then raise exception 'invalid_phone'; end if;
  insert into public.do_not_disturb_phones (organization_id, phone, source, note, created_by)
  values (p_org, v_phone, 'manual', nullif(left(btrim(coalesce(p_note, '')), 300), ''), v_user)
  on conflict (organization_id, phone) where removed_at is null do nothing;
  get diagnostics n = row_count;
  if p_lead is not null and exists (select 1 from public.leads l where l.id = p_lead and l.organization_id = p_org
                                     and private.lead_workable(p_org, l.owner_user_id, l.created_by)) then
    insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
    values (p_org, p_lead, 'dnd_marked', v_user, jsonb_build_object('note', nullif(left(btrim(coalesce(p_note, '')), 300), '')));
  end if;
  return n > 0;
end $$;

-- Remove a phone from the list (supervisor). The row stays, marked removed.
create or replace function public.unmark_phone_dnd(p_org uuid, p_phone text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); n int;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  update public.do_not_disturb_phones set removed_at = now(), removed_by = v_user
  where organization_id = p_org and phone = private.normalize_phone(p_phone) and removed_at is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- A list sent by a bank (or any list): one chunk of phones. Returns how many were added, already there, invalid.
create or replace function public.import_dnd_phones(p_org uuid, p_file_name text, p_phones text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_added int; v_valid int; v_total int := cardinality(coalesce(p_phones, '{}'));
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  if v_total > 5000 then raise exception 'too_many_rows'; end if;
  with norm as (select distinct private.normalize_phone(x) as phone from unnest(coalesce(p_phones, '{}')) x),
       valid as (select phone from norm where phone is not null),
       ins as (insert into public.do_not_disturb_phones (organization_id, phone, source, file_name, created_by)
               select p_org, v.phone, 'import', nullif(left(btrim(coalesce(p_file_name, '')), 255), ''), v_user from valid v
               on conflict (organization_id, phone) where removed_at is null do nothing
               returning 1)
  select (select count(*) from ins), (select count(*) from valid) into v_added, v_valid;
  return jsonb_build_object('added', v_added, 'already', v_valid - v_added,
                            'invalid', v_total - (select count(*) from unnest(coalesce(p_phones, '{}')) x where private.normalize_phone(x) is not null));
end $$;

-- Which of these phones are on the list (the board marks its cards). Phones only: no other data leaves.
create or replace function public.dnd_phones_in(p_org uuid, p_phones text[])
returns setof text language sql stable security definer set search_path = '' as $$
  select d.phone from public.do_not_disturb_phones d
  where (select auth.uid()) is not null and public.has_permission(p_org, 'leads.view')
    and d.organization_id = p_org and d.removed_at is null
    and d.phone in (select private.normalize_phone(x) from unnest(coalesce(p_phones, '{}')) x)
$$;

-- The queue skips leads whose phone is on the list (owner: those leave the queue).
create or replace function private.caller_queue_leads(p_org uuid, p_campaign uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select l.id from public.leads l
  left join public.sales_campaigns c on c.organization_id = l.organization_id and c.id = l.campaign_id
  where l.organization_id = p_org and l.owner_user_id is null and l.status in ('new', 'contacted', 'negotiating')
    and (p_campaign is null or l.campaign_id = p_campaign)
    and public.has_permission(p_org, 'leads.edit')
    and not private.phone_is_dnd(p_org, l.phone) and not private.phone_is_dnd(p_org, l.metadata->>'phone2')
    and case when l.campaign_id is null then
          exists (select 1 from public.organization_lead_settings s where s.organization_id = p_org and s.distribution = 'queue')
        else c.status = 'active' and c.distribution = 'queue'
          and (not exists (select 1 from public.sales_campaign_members m where m.campaign_id = c.id)
               or exists (select 1 from public.sales_campaign_members m where m.campaign_id = c.id and m.user_id = (select auth.uid())))
        end
$$;

revoke all on function public.create_lead_task(uuid, text, text, timestamptz, uuid), public.finish_lead_task(uuid, boolean, text, text),
  public.log_lead_activity(uuid, text, text, text, timestamptz, text), public.save_sales_lead_stage(uuid, uuid, text, text, int, boolean),
  public.move_lead_to_stage(uuid, uuid), public.idle_leads(uuid, int), public.release_leads(uuid, uuid[]),
  public.mark_phone_dnd(uuid, text, text, uuid), public.unmark_phone_dnd(uuid, text), public.import_dnd_phones(uuid, text, text[]),
  public.dnd_phones_in(uuid, text[]) from public, anon;
grant execute on function public.create_lead_task(uuid, text, text, timestamptz, uuid), public.finish_lead_task(uuid, boolean, text, text),
  public.log_lead_activity(uuid, text, text, text, timestamptz, text), public.save_sales_lead_stage(uuid, uuid, text, text, int, boolean),
  public.move_lead_to_stage(uuid, uuid), public.idle_leads(uuid, int), public.release_leads(uuid, uuid[]),
  public.mark_phone_dnd(uuid, text, text, uuid), public.unmark_phone_dnd(uuid, text), public.import_dnd_phones(uuid, text, text[]),
  public.dnd_phones_in(uuid, text[]) to authenticated;

-- Leads passed to another seller (supervisor): their open tasks go to the new owner.
create or replace function private.leads_tasks_follow_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.owner_user_id is not null and old.owner_user_id is distinct from new.owner_user_id then
    update public.lead_tasks set assigned_to = new.owner_user_id, updated_at = now()
    where lead_id = new.id and status = 'open' and assigned_to = old.owner_user_id;
  end if;
  return null;
end $$;
revoke all on function private.leads_tasks_follow_owner() from public, anon, authenticated;
create trigger leads_30_tasks_follow_owner after update of owner_user_id on public.leads
  for each row execute function private.leads_tasks_follow_owner();
