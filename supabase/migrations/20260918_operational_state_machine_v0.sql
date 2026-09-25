-- CORBAN OS V2 — Operational state machine V0
-- PREPARED ONLY. Requires a new live DDL Human Gate before apply.
-- Manual workflow deliberately cannot mark a proposal/case as PAID.

alter table public.proposals_v2 drop constraint if exists proposals_v2_status_check;
alter table public.proposals_v2 add constraint proposals_v2_status_check
  check (status in ('draft','documents_pending','ready_for_digitization','digitization','submitted','approved','paid','rejected','cancelled'));

create or replace function public.guard_proposal_status_transition()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.status is not distinct from old.status then return new; end if;

  if old.status = 'draft' and new.status not in ('documents_pending','ready_for_digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'documents_pending' and new.status not in ('ready_for_digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'ready_for_digitization' and new.status not in ('documents_pending','digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'digitization' and new.status not in ('submitted','rejected','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'submitted' and new.status not in ('approved','rejected','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'approved' and new.status not in ('paid','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status in ('paid','rejected','cancelled') then
    raise exception 'terminal_proposal_status';
  end if;
  return new;
end;
$function$;

create or replace function public.transition_operational_case(
  p_case_id uuid,
  p_to_state text,
  p_raw_external_status text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_org uuid;
  v_from text;
  v_proposal uuid;
  v_job uuid;
  v_stage uuid;
  v_sla integer;
  v_role text;
  v_proposal_status text;
begin
  select c.organization_id,c.canonical_state,c.proposal_id,c.digitization_job_id
    into v_org,v_from,v_proposal,v_job
  from public.operational_cases c
  where c.id=p_case_id and public.is_active_organization_member(c.organization_id)
  for update;

  if v_org is null then raise exception 'operational_case_not_found_or_forbidden'; end if;

  select m.role into v_role from public.organization_memberships m
  where m.organization_id=v_org and m.user_id=auth.uid() and m.status='active';
  if v_role is null then raise exception 'active_membership_required'; end if;

  if p_to_state='paid' then
    raise exception 'paid_requires_confirmed_financial_source';
  end if;

  if not (
    (v_from='digitization_queue' and p_to_state in ('digitizing','cancelled')) or
    (v_from='digitizing' and p_to_state in ('submitted','cancelled')) or
    (v_from='submitted' and p_to_state in ('pending_external','approved','rejected','cancelled')) or
    (v_from='pending_external' and p_to_state in ('approved','rejected','cancelled'))
  ) then raise exception 'invalid_operational_state_transition'; end if;

  if p_to_state in ('approved','rejected','cancelled') and v_role not in ('admin','manager','supervisor') then
    raise exception 'operational_decision_requires_privileged_role';
  end if;

  select s.id,s.sla_minutes into v_stage,v_sla
  from public.operational_stages s
  where s.organization_id=v_org and s.canonical_state=p_to_state and s.is_active=true
  order by s.sort_order,s.created_at limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  update public.operational_cases
  set current_stage_id=v_stage,
      canonical_state=p_to_state,
      entered_stage_at=now(),
      due_at=case when v_sla is null then null else now()+make_interval(mins=>v_sla) end,
      external_status_raw=coalesce(p_raw_external_status,external_status_raw),
      external_status_source=case when p_raw_external_status is null then external_status_source else 'manual' end,
      updated_at=now()
  where organization_id=v_org and id=p_case_id;

  if v_job is not null then
    update public.digitization_jobs
    set status=case
          when p_to_state='digitizing' then 'in_progress'
          when p_to_state in ('submitted','pending_external') then 'submitted'
          when p_to_state='approved' then 'completed'
          when p_to_state in ('rejected','cancelled') then 'cancelled'
          else status end,
        started_at=case when p_to_state='digitizing' then coalesce(started_at,now()) else started_at end,
        submitted_at=case when p_to_state in ('submitted','pending_external','approved') then coalesce(submitted_at,now()) else submitted_at end,
        completed_at=case when p_to_state='approved' then coalesce(completed_at,now()) else completed_at end,
        updated_at=now()
    where organization_id=v_org and id=v_job;
  end if;

  v_proposal_status := case
    when p_to_state='digitizing' then 'digitization'
    when p_to_state in ('submitted','pending_external') then 'submitted'
    when p_to_state='approved' then 'approved'
    when p_to_state='rejected' then 'rejected'
    when p_to_state='cancelled' then 'cancelled'
    else null end;

  if v_proposal_status is not null then
    update public.proposals_v2 set status=v_proposal_status,updated_at=now()
    where organization_id=v_org and id=v_proposal;
  end if;

  insert into public.operational_events(
    organization_id,operational_case_id,event_type,from_state,to_state,
    raw_external_status,source,actor_user_id
  ) values (
    v_org,p_case_id,'state_transition',v_from,p_to_state,
    p_raw_external_status,'corban_os',auth.uid()
  );

  return p_to_state;
end;
$function$;

revoke all on function public.transition_operational_case(uuid,text,text) from public,anon;
grant execute on function public.transition_operational_case(uuid,text,text) to authenticated;
