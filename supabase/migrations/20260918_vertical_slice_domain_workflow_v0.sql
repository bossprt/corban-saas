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

-- Atomically turn a calculated simulation into a proposal and freeze both snapshots.
create or replace function public.create_proposal_from_simulation(p_simulation_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_org uuid;
  v_sim public.simulations%rowtype;
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_table public.product_tables%rowtype;
  v_proposal_id uuid;
begin
  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status <> 'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;
  v_org := v_sim.organization_id;

  select c.* into v_customer from public.clients c
  where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;

  select v.* into v_version from public.product_table_versions v
  where v.organization_id=v_org and v.id=v_sim.product_table_version_id and v.status='published';
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select pt.* into v_table from public.product_tables pt
  where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;

  insert into public.proposals_v2 (
    organization_id, customer_id, simulation_id, product_table_version_id, status,
    requested_amount, released_amount, installment_amount, term, rate, coefficient,
    expected_commission_amount, customer_snapshot, commercial_snapshot,
    attribution_snapshot, created_by
  ) values (
    v_org, v_customer.id, v_sim.id, v_version.id, 'draft',
    v_sim.requested_amount, v_sim.released_amount, v_sim.installment_amount,
    v_sim.term, v_sim.rate, v_sim.coefficient, v_sim.expected_commission_amount,
    jsonb_build_object(
      'full_name', v_customer.full_name, 'cpf', v_customer.cpf,
      'phone', v_customer.phone, 'email', v_customer.email
    ),
    jsonb_build_object(
      'product_table', jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version', jsonb_build_object('id',v_version.id,'version',v_version.version,'rate',v_version.rate,'coefficient',v_version.coefficient)
    ),
    jsonb_build_object('original_source', v_customer.original_source),
    auth.uid()
  ) returning id into v_proposal_id;

  update public.simulations set status='selected', updated_at=now()
  where organization_id=v_org and id=v_sim.id;

  return v_proposal_id;
end;
$function$;

revoke all on function public.create_proposal_from_simulation(uuid) from public, anon;
grant execute on function public.create_proposal_from_simulation(uuid) to authenticated;

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
