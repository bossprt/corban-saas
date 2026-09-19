-- PREPARED, NOT APPLIED. Forward-only; does NOT edit any LIVE migration.
-- URGENT part (fixes a regression introduced by LIVE 20260921_operational_pipeline_write_hardening_v1):
--   public.transition_operational_case (used by /app/operacao) writes operational_cases / digitization_jobs / operational_events and
--   proposals_v2 without the governed-RPC token that the LIVE guard triggers now require, so every esteira transition fails with
--   'operational_write_requires_governed_rpc'. It is redefined below with the token (same rules, same body otherwise).
-- Also here:
--   1. proposals_v2 write governance (token-guarded INSERT/UPDATE, immutable identity columns, no DELETE);
--   2. customer_timeline_events append-only + governed inserts;
--   3. worker support: enqueue_integration_run, list_dispatchable_integration_runs (service_role only, SECURITY INVOKER);
--   4. governed RE-EXECUTION lineage (a NEW run pointing at its terminal parent) distinct from RETRY (same run, governed by claim).
-- No SECURITY DEFINER is created or changed.

-- ===== 1. esteira transition with the operational + proposal tokens =====
create or replace function public.transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text default null)
returns text language plpgsql set search_path to '' as $function$
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

  perform set_config('corban.operational_rpc','on',true);
  perform set_config('corban.proposal_rpc','on',true);
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
  perform set_config('corban.operational_rpc','off',true);
  perform set_config('corban.proposal_rpc','off',true);

  return p_to_state;
end;
$function$;

-- send_proposal_to_digitization: same as LIVE + proposal token around the status update.
create or replace function public.send_proposal_to_digitization(p_proposal_id uuid)
returns uuid language plpgsql set search_path to '' as $function$
declare
  v_org uuid; v_status text; v_stage_id uuid; v_sla integer; v_job_id uuid; v_case_id uuid;
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
  order by s.sort_order, s.created_at limit 1;
  if v_stage_id is null then raise exception 'digitization_queue_stage_not_configured'; end if;
  perform set_config('corban.operational_rpc','on',true);
  perform set_config('corban.proposal_rpc','on',true);
  insert into public.digitization_jobs (organization_id, proposal_id, status, priority) values (v_org, p_proposal_id, 'queued', 0) returning id into v_job_id;
  insert into public.operational_cases (organization_id, proposal_id, digitization_job_id, current_stage_id, canonical_state, due_at)
  values (v_org, p_proposal_id, v_job_id, v_stage_id, 'digitization_queue', case when v_sla is null then null else now() + make_interval(mins => v_sla) end) returning id into v_case_id;
  insert into public.operational_events (organization_id, operational_case_id, event_type, to_state, source, actor_user_id)
  values (v_org, v_case_id, 'queued_for_digitization', 'digitization_queue', 'corban_os', auth.uid());
  update public.proposals_v2 set status='digitization', updated_at=now() where organization_id=v_org and id=p_proposal_id;
  perform set_config('corban.operational_rpc','off',true);
  perform set_config('corban.proposal_rpc','off',true);
  return v_job_id;
end;
$function$;

-- ===== 2. proposals_v2: governed writes =====
create or replace function public.create_proposal_from_simulation(p_simulation_id uuid)
returns uuid language plpgsql set search_path to '' as $function$
declare
  v_org uuid; v_sim public.simulations%rowtype; v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype; v_table public.product_tables%rowtype; v_proposal_id uuid;
begin
  select s.* into v_sim from public.simulations s
  where s.id=p_simulation_id and public.is_active_organization_member(s.organization_id) for update;
  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status <> 'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;
  v_org := v_sim.organization_id;
  select c.* into v_customer from public.clients c where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;
  select v.* into v_version from public.product_table_versions v where v.organization_id=v_org and v.id=v_sim.product_table_version_id and v.status='published';
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;
  select pt.* into v_table from public.product_tables pt where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;
  perform set_config('corban.proposal_rpc','on',true);
  insert into public.proposals_v2 (
    organization_id, customer_id, simulation_id, product_table_version_id, status,
    requested_amount, released_amount, installment_amount, term, rate, coefficient,
    expected_commission_amount, customer_snapshot, commercial_snapshot, attribution_snapshot, created_by
  ) values (
    v_org, v_customer.id, v_sim.id, v_version.id, 'draft',
    v_sim.requested_amount, v_sim.released_amount, v_sim.installment_amount,
    v_sim.term, v_sim.rate, v_sim.coefficient, v_sim.expected_commission_amount,
    jsonb_build_object('full_name', v_customer.full_name, 'cpf', v_customer.cpf, 'phone', v_customer.phone, 'email', v_customer.email),
    jsonb_build_object(
      'product_table', jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version', jsonb_build_object('id',v_version.id,'version',v_version.version,'rate',v_version.rate,'coefficient',v_version.coefficient)),
    jsonb_build_object('original_source', v_customer.original_source),
    auth.uid()
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc','off',true);
  update public.simulations set status='selected', updated_at=now() where organization_id=v_org and id=v_sim.id;
  return v_proposal_id;
end;
$function$;

create or replace function public.prepare_proposal_documents(p_proposal_id uuid)
returns integer language plpgsql set search_path to '' as $function$
declare
  v_org uuid; v_status text; v_template uuid; v_count integer := 0; v_requirement_count integer := 0;
begin
  select p.organization_id, p.status into v_org, v_status from public.proposals_v2 p
  where p.id = p_proposal_id and public.is_active_organization_member(p.organization_id) for update;
  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status not in ('draft','documents_pending') then raise exception 'proposal_not_preparable'; end if;
  select t.id into v_template
  from public.proposals_v2 p
  join public.product_table_versions v on v.organization_id=p.organization_id and v.id=p.product_table_version_id
  join public.product_tables pt on pt.organization_id=v.organization_id and pt.id=v.product_table_id
  join public.document_checklist_templates t on t.organization_id=pt.organization_id and t.route_id=pt.route_id
  where p.organization_id=v_org and p.id=p_proposal_id and t.status='published'
  order by t.version desc limit 1;
  if v_template is null then raise exception 'published_checklist_required'; end if;
  if not exists (select 1 from public.document_checklist_items i where i.organization_id=v_org and i.template_id=v_template) then
    raise exception 'published_checklist_requirements_not_instantiated';
  end if;
  insert into public.proposal_document_requirements (organization_id, proposal_id, checklist_item_id, document_type_id, label_snapshot, required_snapshot)
  select v_org, p_proposal_id, i.id, i.document_type_id, i.label, i.is_required
  from public.document_checklist_items i
  where i.organization_id=v_org and i.template_id=v_template
    and not exists (select 1 from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id and r.checklist_item_id=i.id);
  get diagnostics v_count = row_count;
  select count(*) into v_requirement_count from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id;
  if v_requirement_count = 0 then raise exception 'proposal_requirements_snapshot_empty'; end if;
  perform set_config('corban.proposal_rpc','on',true);
  if exists (select 1 from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id and r.required_snapshot=true and r.status not in ('validated','waived')) then
    update public.proposals_v2 set status='documents_pending', updated_at=now() where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  else
    update public.proposals_v2 set status='ready_for_digitization', updated_at=now() where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  end if;
  perform set_config('corban.proposal_rpc','off',true);
  return v_count;
end;
$function$;

create or replace function public.guard_proposal_write()
returns trigger language plpgsql set search_path='' as $$
begin
 -- Members (authenticated), anon and the worker role may only write proposals through the governed RPCs above (token) or the
 -- paid-evidence RPC (confirm_proposal_paid_from_import sets its own token). Owner-level paths are not affected.
 if current_user in ('authenticated','anon','service_role')
    and current_setting('corban.proposal_rpc',true) is distinct from 'on'
    and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on' then
  raise exception 'proposal_write_requires_governed_rpc';
 end if;
 if tg_op='UPDATE' and (new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.customer_id is distinct from old.customer_id
    or new.simulation_id is distinct from old.simulation_id or new.product_table_version_id is distinct from old.product_table_version_id
    or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at) then
  raise exception 'proposal_identity_is_immutable';
 end if;
 return new;
end $$;
revoke all on function public.guard_proposal_write() from public,anon,authenticated;
-- Named to sort BEFORE the older guards on this table (triggers fire alphabetically) so the governed-write error is the first one raised.
create trigger proposals_v2_00_governed_write before insert or update on public.proposals_v2 for each row execute function public.guard_proposal_write();
revoke delete on table public.proposals_v2 from authenticated;

-- ===== 3. customer timeline: append-only, governed inserts =====
create or replace function public.guard_customer_timeline_write()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='UPDATE' then raise exception 'customer_timeline_is_append_only'; end if;
 if current_user in ('authenticated','anon','service_role') and current_setting('corban.timeline_rpc',true) is distinct from 'on' then
  raise exception 'timeline_write_requires_governed_rpc';
 end if;
 return new;
end $$;
revoke all on function public.guard_customer_timeline_write() from public,anon,authenticated;
create trigger trg_customer_timeline_write before insert or update on public.customer_timeline_events for each row execute function public.guard_customer_timeline_write();

create or replace function public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text default null, p_email text default null, p_original_source text default 'corban_os')
returns uuid language plpgsql set search_path to '' as $function$
declare v_customer_id uuid;
begin
 if p_organization_id is null or not public.is_active_organization_member(p_organization_id) then raise exception 'active_membership_required'; end if;
 if nullif(btrim(p_full_name),'') is null then raise exception 'full_name_required'; end if;
 if p_cpf !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
 insert into public.clients(organization_id,full_name,cpf,phone,email,original_source)
 values(p_organization_id,btrim(p_full_name),p_cpf,nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),p_original_source) returning id into v_customer_id;
 perform set_config('corban.timeline_rpc','on',true);
 insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id)
 values(p_organization_id,v_customer_id,'customer.created','corban_os',(select auth.uid()));
 perform set_config('corban.timeline_rpc','off',true);
 return v_customer_id;
end $function$;

-- ===== 4. integration runs: lineage, enqueue, dispatch =====
alter table public.integration_runs
 add column if not exists parent_run_id uuid references public.integration_runs(id),
 add column if not exists reexecution_reason text;
alter table public.integration_runs
 add constraint integration_runs_reexec_reason_len check (reexecution_reason is null or length(reexecution_reason) between 10 and 500),
 add constraint integration_runs_reexec_pair check ((parent_run_id is null) = (reexecution_reason is null)),
 add constraint integration_runs_not_own_parent check (parent_run_id is distinct from id);
create unique index if not exists integration_runs_parent_uidx on public.integration_runs(parent_run_id) where parent_run_id is not null;
create index if not exists integration_runs_dispatch_idx on public.integration_runs(status,next_attempt_at,lease_expires_at) where status in ('queued','failed','running');

-- Same guard as LIVE + lineage: parent must be same tenant and immutable afterwards.
create or replace function public.guard_integration_run_state()
returns trigger language plpgsql set search_path='' as $$
declare ok boolean; p_org uuid;
begin
 if tg_op='DELETE' then raise exception 'integration_run_cannot_be_deleted'; end if;
 if current_setting('corban.integration_run_rpc',true) is distinct from 'on' then raise exception 'integration_run_requires_governed_rpc'; end if;
 if public.integration_content_has_secret(new.metadata::text) or public.integration_content_has_secret(new.error_message) or public.integration_content_has_secret(new.reexecution_reason) then raise exception 'integration_run_secret_like_content'; end if;
 if tg_op='INSERT' then
  if new.status<>'queued' or new.attempt_count<>0 or new.terminal or new.claim_token is not null then raise exception 'integration_run_must_start_queued'; end if;
  if new.parent_run_id is not null then
   select organization_id into p_org from public.integration_runs where id=new.parent_run_id;
   if p_org is null or p_org<>new.organization_id then raise exception 'integration_run_parent_tenant_mismatch'; end if;
  end if;
  return new;
 end if;
 if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.binding_id is distinct from old.binding_id
    or new.adapter_id is distinct from old.adapter_id or new.capability is distinct from old.capability or new.request_fingerprint is distinct from old.request_fingerprint
    or new.max_attempts is distinct from old.max_attempts or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by
    or new.parent_run_id is distinct from old.parent_run_id or new.reexecution_reason is distinct from old.reexecution_reason then
  raise exception 'integration_run_identity_is_immutable';
 end if;
 ok:=(old.status='queued' and new.status in ('running','cancelled'))
  or (old.status='running' and new.status in ('running','succeeded','failed'))
  or (old.status='failed' and new.status in ('running','cancelled') and not old.terminal and old.attempt_count<old.max_attempts);
 if not ok then raise exception 'illegal_integration_run_transition: % -> %',old.status,new.status; end if;
 if new.status='running' and new.attempt_count<>old.attempt_count+1 then raise exception 'integration_run_attempt_must_increment'; end if;
 if new.status<>'running' and new.attempt_count<>old.attempt_count then raise exception 'integration_run_attempt_is_derived'; end if;
 if new.status='succeeded' then
  if new.error_code is not null or new.terminal then raise exception 'successful run cannot carry an error'; end if;
  if not exists(select 1 from public.integration_run_artifacts a where a.run_id=new.id and a.organization_id=new.organization_id and a.artifact_kind='response_metadata') then raise exception 'success_requires_response_evidence'; end if;
 end if;
 if new.status='failed' and nullif(btrim(new.error_code),'') is null then raise exception 'failed_run_requires_error_code'; end if;
 if new.status in ('succeeded','failed','cancelled') then new.claim_token:=null; new.lease_expires_at:=null; new.finished_at:=coalesce(new.finished_at,now()); end if;
 if new.status='running' then new.finished_at:=null; end if;
 new.updated_at:=now();
 return new;
end $$;

create or replace function public.enqueue_integration_run(p_org uuid,p_binding uuid,p_capability text,p_fingerprint text,p_actor uuid,p_max_attempts integer,p_request jsonb,p_correlation text,p_adapter_key text default null)
returns table(run_id uuid,status text,created boolean)
language plpgsql set search_path='' as $$
declare v_adapter uuid;v_adapter_key text;v_id uuid;v_status text;
begin
 if p_max_attempts is null or p_max_attempts not between 1 and 10 then raise exception 'invalid_max_attempts'; end if;
 if p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager','supervisor')) then raise exception 'actor_not_authorized'; end if;
 select b.adapter_id,a.adapter_key into v_adapter,v_adapter_key from public.integration_source_bindings b join public.integration_adapters a on a.id=b.adapter_id where b.id=p_binding and b.organization_id=p_org and b.enabled;
 if v_adapter is null then raise exception 'binding_not_found'; end if;
 if p_adapter_key is not null and p_adapter_key<>v_adapter_key then raise exception 'adapter_mismatch'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id)
 values(p_org,p_binding,v_adapter,p_capability,'queued',p_fingerprint,p_max_attempts,jsonb_build_object('request',coalesce(p_request,'{}'::jsonb)),p_actor,left(p_correlation,128))
 on conflict(organization_id,binding_id,request_fingerprint) do nothing returning id into v_id;
 perform set_config('corban.integration_run_rpc','off',true);
 if v_id is not null then return query select v_id,'queued'::text,true; return; end if;
 select r.id,r.status into v_id,v_status from public.integration_runs r where r.organization_id=p_org and r.binding_id=p_binding and r.request_fingerprint=p_fingerprint;
 return query select v_id,v_status,false;
end $$;

create or replace function public.list_dispatchable_integration_runs(p_limit integer,p_now timestamptz default now())
returns table(run_id uuid,organization_id uuid,binding_id uuid,adapter_key text,capability text,fingerprint text,correlation_id text,status text,attempt_count integer,max_attempts integer,request jsonb,actor_user_id uuid)
language sql stable set search_path='' as $$
 select r.id,r.organization_id,r.binding_id,a.adapter_key,r.capability,r.request_fingerprint,r.correlation_id,r.status,r.attempt_count,r.max_attempts,r.metadata->'request',r.created_by
 from public.integration_runs r
 join public.integration_source_bindings b on b.id=r.binding_id and b.organization_id=r.organization_id and b.enabled
 join public.integration_adapters a on a.id=r.adapter_id and a.status<>'disabled'
 where r.status='queued'
    or (r.status='failed' and not r.terminal and r.attempt_count<r.max_attempts and r.next_attempt_at<=p_now)
    or (r.status='running' and r.lease_expires_at<=p_now)
 order by r.created_at
 limit least(greatest(coalesce(p_limit,10),1),50)
$$;

-- New EXECUTION (not a retry): a fresh run that points to its terminal parent. Idempotent per parent. Never touches the parent.
create or replace function public.create_integration_reexecution(p_org uuid,p_parent uuid,p_actor uuid,p_reason text,p_correlation text)
returns table(run_id uuid,fingerprint text,created boolean)
language plpgsql set search_path='' as $$
declare v_parent public.integration_runs%rowtype;v_child uuid;v_fp text;
begin
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager')) then raise exception 'actor_not_authorized'; end if;
 if p_reason is null or length(btrim(p_reason)) not between 10 and 500 then raise exception 'reexecution_reason_length_invalid'; end if;
 select * into v_parent from public.integration_runs r where r.id=p_parent and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 select r.id,r.request_fingerprint into v_child,v_fp from public.integration_runs r where r.parent_run_id=p_parent;
 if v_child is not null then return query select v_child,v_fp,false; return; end if;
 if not ((v_parent.status='failed' and (v_parent.terminal or v_parent.attempt_count>=v_parent.max_attempts)) or v_parent.status='cancelled') then raise exception 'parent_not_reexecutable'; end if;
 v_fp:=encode(extensions.digest(v_parent.request_fingerprint||':reexec:'||p_parent::text,'sha256'),'hex');
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id,parent_run_id,reexecution_reason)
 values(p_org,v_parent.binding_id,v_parent.adapter_id,v_parent.capability,'queued',v_fp,v_parent.max_attempts,jsonb_build_object('request',coalesce(v_parent.metadata->'request','{}'::jsonb),'reexecution_of',p_parent),p_actor,left(coalesce(p_correlation,v_parent.correlation_id),128),p_parent,btrim(p_reason))
 returning id into v_child;
 perform set_config('corban.integration_run_rpc','off',true);
 return query select v_child,v_fp,true;
end $$;

revoke all on function public.enqueue_integration_run(uuid,uuid,text,text,uuid,integer,jsonb,text,text),public.list_dispatchable_integration_runs(integer,timestamptz),public.create_integration_reexecution(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.enqueue_integration_run(uuid,uuid,text,text,uuid,integer,jsonb,text,text),public.list_dispatchable_integration_runs(integer,timestamptz),public.create_integration_reexecution(uuid,uuid,uuid,text,text) to service_role;
