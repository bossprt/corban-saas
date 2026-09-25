-- CORBAN OS V2 — Financial Truth Guard Trigger V0
-- Defense in depth: direct table INSERT cannot forge evidence-backed truth.
create or replace function public.guard_financial_event_insert()
returns trigger language plpgsql set search_path=public as $$
begin
 if new.event_type in ('commission_reported','payment_received','downstream_paid') then
  if current_setting('corban.financial_evidence_rpc',true) is distinct from 'on' then raise exception 'financial_fact_requires_evidence_rpc'; end if;
 end if;
 return new;
end $$;
drop trigger if exists financial_event_insert_guard on public.financial_events;
create trigger financial_event_insert_guard before insert on public.financial_events for each row execute function public.guard_financial_event_insert();
revoke all on function public.guard_financial_event_insert() from public,anon,authenticated;

-- Replace publisher with identical governed semantics plus transaction-local guard.
create or replace function public.publish_financial_evidence_event(
 p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric,
 p_occurred_at timestamptz, p_source_kind text, p_source_reference text,
 p_import_batch_id uuid default null, p_import_raw_row_id uuid default null, p_import_decision_id uuid default null
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_event uuid;v_channel uuid;v_producer uuid;v_payer uuid;v_key text;v_semantic text;v_raw_batch uuid;v_decision_batch uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence') then raise exception 'confirmed_evidence_source_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id,producer_entity_id,payer_entity_id into v_channel,v_producer,v_payer from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 if not found then raise exception 'frozen_commercial_snapshot_required'; end if;
 if p_source_kind='import' then
  if p_import_batch_id is null then raise exception 'import_batch_required'; end if;
  select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=p_import_batch_id and b.organization_id=v_org;
  if v_semantic is null then raise exception 'batch_not_found'; end if;
  if p_event_type='commission_reported' and v_semantic<>'commission_statement' then raise exception 'source_does_not_prove_reported_commission'; end if;
  if p_event_type='payment_received' and v_semantic<>'payment_statement' then raise exception 'source_does_not_prove_payment'; end if;
  if p_event_type='downstream_paid' and v_semantic<>'network_payment_statement' then raise exception 'source_does_not_prove_network_payment'; end if;
  if p_import_raw_row_id is not null then select batch_id into v_raw_batch from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org; if v_raw_batch is distinct from p_import_batch_id then raise exception 'raw_row_batch_mismatch'; end if; end if;
  if p_import_decision_id is not null then select batch_id into v_decision_batch from public.import_decisions where id=p_import_decision_id and organization_id=v_org; if v_decision_batch is distinct from p_import_batch_id then raise exception 'decision_batch_mismatch'; end if; end if;
 elsif nullif(trim(p_source_reference),'') is null then raise exception 'external_evidence_reference_required'; end if;
 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||encode(digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is null then
  perform set_config('corban.financial_evidence_rpc','on',true);
  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,jsonb_build_object('evidence_semantic',v_semantic),v_user) returning id into v_event;
  perform set_config('corban.financial_evidence_rpc','off',true);
 end if;
 insert into public.financial_evidence_links(organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,evidence_kind,evidence_reference)
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference where not exists(select 1 from public.financial_evidence_links where financial_event_id=v_event and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000') and coalesce(evidence_reference,'')=coalesce(p_source_reference,''));
 return v_event;
end $$;
