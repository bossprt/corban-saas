-- PREPARED, NOT APPLIED (Human Gate: DDL on live operational tables; replaces one live function).
-- Finding (operational E2E, 2026-09-21): operational_cases, operational_events and digitization_jobs accept INSERT/UPDATE from ANY
-- active member through plain RLS policies (is_active_organization_member), and authenticated also holds UPDATE/DELETE grants on
-- operational_events. An agent could therefore forge esteira history, jump a case to canonical_state='paid', or rewrite a job outcome
-- by talking to PostgREST directly. This is not ledger truth, but the esteira is what operators read as "what happened".
-- The application only READS these tables; the single writer is send_proposal_to_digitization (SECURITY INVOKER).
-- Fix (same guard-token pattern as the rest of the schema):
--   * INSERT/UPDATE on the three tables require a transaction-local token that only the governed RPC sets;
--   * operational_events is append-only (no UPDATE/DELETE privilege, plus a trigger for owner-level paths);
--   * DELETE privilege is revoked from authenticated on all three tables and on customer_timeline_events (no policy allowed it; the
--     grant was dead weight) and UPDATE is revoked on customer_timeline_events (history is append-only).
revoke delete on table public.operational_cases,public.operational_events,public.digitization_jobs,public.customer_timeline_events from authenticated;
revoke update on table public.operational_events,public.customer_timeline_events from authenticated;

create or replace function public.guard_operational_pipeline_write()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_table_name='operational_events' and tg_op<>'INSERT' then raise exception 'operational_events_are_append_only'; end if;
 if current_setting('corban.operational_rpc',true) is distinct from 'on' then raise exception 'operational_write_requires_governed_rpc'; end if;
 return new;
end $$;
revoke all on function public.guard_operational_pipeline_write() from public,anon,authenticated;
create trigger trg_operational_cases_write before insert or update on public.operational_cases for each row execute function public.guard_operational_pipeline_write();
create trigger trg_operational_events_write before insert or update on public.operational_events for each row execute function public.guard_operational_pipeline_write();
create trigger trg_digitization_jobs_write before insert or update on public.digitization_jobs for each row execute function public.guard_operational_pipeline_write();

create or replace function public.send_proposal_to_digitization(p_proposal_id uuid)
returns uuid language plpgsql set search_path to '' as $function$
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

  perform set_config('corban.operational_rpc','on',true);
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
  perform set_config('corban.operational_rpc','off',true);

  update public.proposals_v2 set status='digitization', updated_at=now()
  where organization_id=v_org and id=p_proposal_id;

  return v_job_id;
end;
$function$;
