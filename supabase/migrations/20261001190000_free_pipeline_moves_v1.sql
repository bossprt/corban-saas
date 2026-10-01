-- Esteira simples (owner request 01/10/2026): a proposal moves from any stage to any stage (Kanban drag and drop, the
-- status list in the table, the contract page). The note and the pendency due date are optional. Every move is in the
-- history (who, when, from, to). The one lock protects money: a paid contract with commission received from the bank
-- or a payout to the seller does not leave "Paga", and only an admin or manager takes a contract out of "Paga".

-- The proposal status follows the stage; a governed stage move may go back or reopen (the paid evidence rule stays).
CREATE OR REPLACE FUNCTION public.guard_proposal_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if new.status is not distinct from old.status then return new; end if;
 if new.status='paid' and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on' then raise exception 'paid_requires_confirmed_operational_evidence'; end if;
 if current_setting('corban.stage_move_rpc',true) = 'on' then return new; end if;
 if old.status='draft' and new.status not in ('documents_pending','ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='documents_pending' and new.status not in ('ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='ready_for_digitization' and new.status not in ('documents_pending','digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='digitization' and new.status not in ('submitted','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='submitted' and new.status not in ('approved','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='approved' and new.status not in ('paid','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status in ('paid','rejected','cancelled') then raise exception 'terminal_proposal_status'; end if;
 return new;
end $function$;

-- Moves a case to one of the company's stages (any stage, forwards or back).
CREATE OR REPLACE FUNCTION public.move_case_to_stage(p_case_id uuid, p_stage_id uuid, p_note text DEFAULT NULL::text, p_pendency_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_paid_on date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.operational_cases%rowtype;
  s public.operational_stages%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_paid_on date := coalesce(p_paid_on, current_date);
  v_old_status text;
  v_status text;
begin
  select * into c from public.operational_cases where id = p_case_id for update;
  if not found or auth.uid() is null or not public.is_active_organization_member(c.organization_id) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  if not exists (
    select 1 from public.proposals_v2 p
    where p.id = c.proposal_id and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
  ) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  if not public.has_permission(c.organization_id, 'esteira.edit') then raise exception 'not_authorized'; end if;

  select * into s from public.operational_stages where id = p_stage_id and organization_id = c.organization_id and is_active;
  if s.id is null then raise exception 'target_operational_stage_not_configured'; end if;
  if s.id = c.current_stage_id then return s.canonical_state; end if;
  if v_note is not null and length(v_note) > 500 then raise exception 'invalid_note'; end if;
  if s.canonical_state = 'paid' and v_paid_on > current_date then raise exception 'invalid_paid_on'; end if;

  select p.status into v_old_status from public.proposals_v2 p where p.id = c.proposal_id for update;
  -- Leaving "Paga": only an admin or manager, and never once money moved for the contract.
  if v_old_status = 'paid' and s.canonical_state <> 'paid' then
    if not public.has_active_organization_role(c.organization_id, array['admin', 'manager']) then raise exception 'leaving_paid_requires_manager'; end if;
    if exists (select 1 from public.commission_receipts x where x.proposal_id = c.proposal_id)
       or exists (select 1 from public.payout_entries e where e.proposal_id = c.proposal_id and e.source = 'contract' and e.status <> 'rejected') then
      raise exception 'paid_contract_has_money';
    end if;
  end if;

  perform set_config('corban.operational_rpc', 'on', true);
  perform set_config('corban.proposal_rpc', 'on', true);
  perform set_config('corban.stage_move_rpc', 'on', true);
  update public.operational_cases
  set current_stage_id = s.id,
      canonical_state = s.canonical_state,
      entered_stage_at = now(),
      due_at = case when s.sla_minutes is null then null else now() + make_interval(mins => s.sla_minutes) end,
      pendency_reason = case when s.canonical_state = 'pending_external' then v_note end,
      pendency_due_at = case when s.canonical_state = 'pending_external' then p_pendency_due_at end,
      updated_at = now()
  where id = c.id;

  if c.digitization_job_id is not null then
    update public.digitization_jobs
    set status = case
          when s.canonical_state = 'digitization_queue' then status
          when s.canonical_state = 'digitizing' then 'in_progress'
          when s.canonical_state in ('submitted', 'pending_external') then 'submitted'
          when s.canonical_state in ('approved', 'paid') then 'completed'
          when s.canonical_state in ('rejected', 'cancelled') then 'cancelled'
          else status end,
        started_at = case when s.canonical_state = 'digitizing' then coalesce(started_at, now()) else started_at end,
        updated_at = now()
    where organization_id = c.organization_id and id = c.digitization_job_id;
  end if;

  v_status := case
    when s.canonical_state in ('digitization_queue', 'digitizing') then 'digitization'
    when s.canonical_state in ('submitted', 'pending_external') then 'submitted'
    else s.canonical_state end;
  if s.canonical_state = 'paid' then
    perform set_config('corban.paid_evidence_rpc', 'on', true);
    update public.proposals_v2 set status = 'paid', paid_to_client_on = v_paid_on, updated_at = now() where id = c.proposal_id;
    insert into public.proposal_status_evidence (organization_id, proposal_id, canonical_status, raw_status, evidenced_at, created_by, source, note)
    values (c.organization_id, c.proposal_id, 'paid', 'manual', now(), auth.uid(), 'manual', coalesce(v_note, 'Movida para Paga'));
    perform set_config('corban.paid_evidence_rpc', 'off', true);
  elsif v_status is distinct from v_old_status then
    update public.proposals_v2
    set status = v_status, paid_to_client_on = case when v_old_status = 'paid' then null else paid_to_client_on end, updated_at = now()
    where id = c.proposal_id;
  end if;

  insert into public.operational_events (organization_id, operational_case_id, event_type, from_state, to_state, source, actor_user_id, metadata)
  values (c.organization_id, c.id, 'state_transition', c.canonical_state, s.canonical_state, 'corban_os', auth.uid(),
          jsonb_build_object('note', v_note, 'pendency_due_at', p_pendency_due_at, 'paid_on', case when s.canonical_state = 'paid' then v_paid_on end,
                             'from_stage_id', c.current_stage_id, 'to_stage_id', s.id));
  perform set_config('corban.stage_move_rpc', 'off', true);
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return s.canonical_state;
end
$function$;

-- The former call by state: the first active stage of that state. Runs as the caller (it reads only what the caller
-- sees); the move itself is checked by move_case_to_stage.
CREATE OR REPLACE FUNCTION public.move_operational_case(p_case_id uuid, p_to_state text, p_note text DEFAULT NULL::text, p_pendency_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_paid_on date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
declare v_stage uuid;
begin
  select s.id into v_stage from public.operational_stages s
  join public.operational_cases c on c.organization_id = s.organization_id
  where c.id = p_case_id and s.canonical_state = p_to_state and s.is_active
  order by s.sort_order, s.created_at limit 1;
  if v_stage is null then raise exception 'operational_case_not_found_or_forbidden'; end if;
  return public.move_case_to_stage(p_case_id, v_stage, p_note, p_pendency_due_at, p_paid_on);
end
$function$;

revoke all on function public.move_case_to_stage(uuid, uuid, text, timestamp with time zone, date) from public, anon;
grant execute on function public.move_case_to_stage(uuid, uuid, text, timestamp with time zone, date) to authenticated;
revoke all on function public.move_operational_case(uuid, text, text, timestamp with time zone, date) from public, anon;
grant execute on function public.move_operational_case(uuid, text, text, timestamp with time zone, date) to authenticated;
