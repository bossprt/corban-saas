-- CORBAN OS V2 — Vertical Slice domain workflow V0
-- PREPARED ONLY. Human Gate required before applying live.
-- Adds deterministic proposal/document/digitization primitives without weakening RLS.

-- One proposal per simulation. External/manual proposals keep simulation_id null.
create unique index if not exists proposals_v2_org_simulation_unique
  on public.proposals_v2 (organization_id, simulation_id)
  where simulation_id is not null;

-- A selected simulation is historical commercial evidence. Commercial inputs cannot change.
create or replace function public.guard_simulation_selected_immutable()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if old.status in ('selected','expired','cancelled') then
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.expected_commission_amount is distinct from old.expected_commission_amount
       or new.input_snapshot is distinct from old.input_snapshot
       or new.result_snapshot is distinct from old.result_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'selected_simulation_snapshot_is_immutable';
    end if;
  end if;

  if old.status = 'selected' and new.status not in ('selected','expired','cancelled') then
    raise exception 'invalid_selected_simulation_transition';
  end if;
  if old.status in ('expired','cancelled') and new.status is distinct from old.status then
    raise exception 'terminal_simulation_status';
  end if;
  return new;
end;
$function$;

drop trigger if exists simulations_selected_immutable_guard on public.simulations;
create trigger simulations_selected_immutable_guard
before update on public.simulations
for each row execute function public.guard_simulation_selected_immutable();

revoke all on function public.guard_simulation_selected_immutable() from public, anon, authenticated;

-- Proposal workflow graph for the currently deployed V0 status vocabulary.
create or replace function public.guard_proposal_status_transition()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  if old.status = 'draft' and new.status not in ('documents_pending','ready_for_digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'documents_pending' and new.status not in ('ready_for_digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'ready_for_digitization' and new.status not in ('documents_pending','digitization','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'digitization' and new.status not in ('submitted','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'submitted' and new.status not in ('approved','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status = 'approved' and new.status not in ('paid','cancelled') then
    raise exception 'invalid_proposal_status_transition';
  elsif old.status in ('paid','cancelled') then
    raise exception 'terminal_proposal_status';
  end if;

  return new;
end;
$function$;

drop trigger if exists proposals_v2_status_transition_guard on public.proposals_v2;
create trigger proposals_v2_status_transition_guard
before update of status on public.proposals_v2
for each row execute function public.guard_proposal_status_transition();

revoke all on function public.guard_proposal_status_transition() from public, anon, authenticated;

-- Snapshot the latest published checklist for the proposal's exact tenant route.
create or replace function public.prepare_proposal_documents(p_proposal_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_org uuid;
  v_status text;
  v_template uuid;
  v_count integer := 0;
begin
  select p.organization_id, p.status
    into v_org, v_status
  from public.proposals_v2 p
  where p.id = p_proposal_id
    and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status not in ('draft','documents_pending') then raise exception 'proposal_not_preparable'; end if;

  select t.id into v_template
  from public.proposals_v2 p
  join public.product_table_versions v
    on v.organization_id=p.organization_id and v.id=p.product_table_version_id
  join public.product_tables pt
    on pt.organization_id=v.organization_id and pt.id=v.product_table_id
  join public.document_checklist_templates t
    on t.organization_id=pt.organization_id and t.route_id=pt.route_id
  where p.organization_id=v_org and p.id=p_proposal_id and t.status='published'
  order by t.version desc
  limit 1;

  if v_template is not null then
    insert into public.proposal_document_requirements (
      organization_id, proposal_id, checklist_item_id, document_type_id,
      label_snapshot, required_snapshot
    )
    select v_org, p_proposal_id, i.id, i.document_type_id, i.label, i.is_required
    from public.document_checklist_items i
    where i.organization_id=v_org and i.template_id=v_template
      and not exists (
        select 1 from public.proposal_document_requirements r
        where r.organization_id=v_org and r.proposal_id=p_proposal_id
          and r.checklist_item_id=i.id
      );
    get diagnostics v_count = row_count;
  end if;

  if exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id=v_org and r.proposal_id=p_proposal_id
      and r.required_snapshot=true and r.status not in ('validated','waived')
  ) then
    update public.proposals_v2 set status='documents_pending', updated_at=now()
    where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  else
    update public.proposals_v2 set status='ready_for_digitization', updated_at=now()
    where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  end if;

  return v_count;
end;
$function$;

revoke all on function public.prepare_proposal_documents(uuid) from public, anon;
grant execute on function public.prepare_proposal_documents(uuid) to authenticated;

-- Transactional queue primitive. It creates the queue job, operational case and immutable event together.
create or replace function public.send_proposal_to_digitization(p_proposal_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_org uuid;
  v_status text;
  v_stage_id uuid;
  v_sla integer;
  v_job_id uuid;
  v_case_id uuid;
begin
  select p.organization_id, p.status into v_org, v_status
  from public.proposals_v2 p
  where p.id=p_proposal_id and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status <> 'ready_for_digitization' then raise exception 'proposal_not_ready_for_digitization'; end if;

  if exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id=v_org and r.proposal_id=p_proposal_id
      and r.required_snapshot=true and r.status not in ('validated','waived')
  ) then raise exception 'required_documents_not_ready'; end if;

  select s.id, s.sla_minutes into v_stage_id, v_sla
  from public.operational_stages s
  where s.organization_id=v_org and s.canonical_state='digitization_queue' and s.is_active=true
  order by s.sort_order, s.created_at
  limit 1;

  if v_stage_id is null then raise exception 'digitization_queue_stage_not_configured'; end if;

  insert into public.digitization_jobs (organization_id, proposal_id, status, priority)
  values (v_org, p_proposal_id, 'queued', 0)
  returning id into v_job_id;

  insert into public.operational_cases (
    organization_id, proposal_id, digitization_job_id, current_stage_id,
    canonical_state, due_at
  ) values (
    v_org, p_proposal_id, v_job_id, v_stage_id, 'digitization_queue',
    case when v_sla is null then null else now() + make_interval(mins => v_sla) end
  ) returning id into v_case_id;

  insert into public.operational_events (
    organization_id, operational_case_id, event_type, to_state, source, actor_user_id
  ) values (
    v_org, v_case_id, 'queued_for_digitization', 'digitization_queue', 'corban_os', auth.uid()
  );

  update public.proposals_v2 set status='digitization', updated_at=now()
  where organization_id=v_org and id=p_proposal_id;

  return v_job_id;
end;
$function$;

revoke all on function public.send_proposal_to_digitization(uuid) from public, anon;
grant execute on function public.send_proposal_to_digitization(uuid) to authenticated;

-- Authenticated users never receive direct DELETE from this migration.
