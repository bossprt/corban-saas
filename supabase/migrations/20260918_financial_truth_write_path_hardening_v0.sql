-- CORBAN OS V2 — Financial Truth Write Path Hardening V0
-- Triple-reviewed corrective hardening under pre-authorized autonomous mandate.

-- One reconciliation case per proposal/component, including NULL component.
create unique index if not exists financial_reconciliation_case_identity_uq
on public.financial_reconciliation_cases(organization_id,proposal_id,coalesce(component_type,'__none__'));

-- Financial truth is readable to tenant members, but authenticated clients cannot directly forge ledger facts.
drop policy if exists financial_events_insert_supervisor on public.financial_events;
drop policy if exists financial_reconciliation_cases_insert_supervisor on public.financial_reconciliation_cases;
drop policy if exists financial_reconciliation_cases_update_supervisor on public.financial_reconciliation_cases;
revoke insert,update,delete on public.financial_events from authenticated;
revoke insert,update,delete on public.financial_evidence_links from authenticated;
revoke insert,update,delete on public.financial_reconciliation_cases from authenticated;

create or replace function public.publish_financial_evidence_event(
 p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric,
 p_occurred_at timestamptz, p_source_kind text, p_source_reference text,
 p_import_batch_id uuid default null, p_import_raw_row_id uuid default null, p_import_decision_id uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
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
  if p_import_raw_row_id is not null then
   select batch_id into v_raw_batch from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org;
   if v_raw_batch is distinct from p_import_batch_id then raise exception 'raw_row_batch_mismatch'; end if;
  end if;
  if p_import_decision_id is not null then
   select batch_id into v_decision_batch from public.import_decisions where id=p_import_decision_id and organization_id=v_org;
   if v_decision_batch is distinct from p_import_batch_id then raise exception 'decision_batch_mismatch'; end if;
  end if;
 elsif nullif(trim(p_source_reference),'') is null then raise exception 'external_evidence_reference_required'; end if;

 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||
 encode(digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is null then
  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,jsonb_build_object('evidence_semantic',v_semantic),v_user) returning id into v_event;
 end if;
 insert into public.financial_evidence_links(organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,evidence_kind,evidence_reference)
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference
 where not exists(select 1 from public.financial_evidence_links where financial_event_id=v_event and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000') and coalesce(evidence_reference,'')=coalesce(p_source_reference,''));
 return v_event;
end $$;
revoke all on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) to authenticated;

create or replace function public.refresh_financial_reconciliation(p_proposal_id uuid,p_component_type text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_channel uuid;v_expected numeric;v_reported numeric;v_settled numeric;v_case uuid;v_status text;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id into v_channel from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 select coalesce(sum(case when event_type='commission_expected' then amount when event_type in ('reversal','adjustment') and metadata->>'affects'='expected' then amount else 0 end),0),
        coalesce(sum(case when event_type='commission_reported' then amount when event_type in ('reversal','adjustment') and metadata->>'affects'='reported' then amount else 0 end),0),
        coalesce(sum(case when event_type='payment_received' then amount when event_type in ('reversal','adjustment') and metadata->>'affects'='settled' then amount else 0 end),0)
 into v_expected,v_reported,v_settled from public.financial_events where organization_id=v_org and proposal_id=p_proposal_id and component_type is not distinct from p_component_type;
 v_status:=case when v_expected=0 and (v_reported>0 or v_settled>0) then 'human_required'
  when v_settled=v_expected and v_expected>0 then 'matched'
  when v_reported=0 and v_settled=0 then 'open'
  when v_reported<>v_expected or v_settled<>v_expected then 'divergent' else 'open' end;
 insert into public.financial_reconciliation_cases(organization_id,proposal_id,channel_id,component_type,expected_amount,reported_amount,settled_amount,status)
 values(v_org,p_proposal_id,v_channel,p_component_type,v_expected,v_reported,v_settled,v_status)
 on conflict(organization_id,proposal_id,(coalesce(component_type,'__none__'))) do update set expected_amount=excluded.expected_amount,reported_amount=excluded.reported_amount,settled_amount=excluded.settled_amount,status=excluded.status,updated_at=now()
 returning id into v_case;
 return v_case;
end $$;
revoke all on function public.refresh_financial_reconciliation(uuid,text) from public,anon;
grant execute on function public.refresh_financial_reconciliation(uuid,text) to authenticated;
