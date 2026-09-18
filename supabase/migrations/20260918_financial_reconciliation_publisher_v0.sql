-- CORBAN OS V2 — Financial Reconciliation Publisher V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Reported and settled facts require evidence; neither is inferred from proposal matching.

create or replace function public.publish_financial_evidence_event(
 p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric,
 p_occurred_at timestamptz, p_source_kind text, p_source_reference text,
 p_import_batch_id uuid default null, p_import_raw_row_id uuid default null, p_import_decision_id uuid default null
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid(); v_org uuid; v_event uuid; v_channel uuid; v_producer uuid; v_payer uuid; v_key text;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence','manual_review') then raise exception 'evidence_source_required'; end if;
 if nullif(trim(p_source_reference),'') is null and p_import_batch_id is null and p_import_raw_row_id is null and p_import_decision_id is null then raise exception 'evidence_reference_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id,producer_entity_id,payer_entity_id into v_channel,v_producer,v_payer from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 if not found then raise exception 'frozen_commercial_snapshot_required'; end if;
 if p_import_batch_id is not null and not exists(select 1 from public.import_batches where id=p_import_batch_id and organization_id=v_org) then raise exception 'batch_tenant_mismatch'; end if;
 if p_import_raw_row_id is not null and not exists(select 1 from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org) then raise exception 'raw_row_tenant_mismatch'; end if;
 if p_import_decision_id is not null and not exists(select 1 from public.import_decisions where id=p_import_decision_id and organization_id=v_org) then raise exception 'decision_tenant_mismatch'; end if;
 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||coalesce(p_source_reference,p_import_decision_id::text,p_import_raw_row_id::text,p_import_batch_id::text);
 insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
 values(v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,'{}'::jsonb,v_user)
 on conflict(organization_id,idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_event;
 insert into public.financial_evidence_links(organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,evidence_kind,evidence_reference)
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference
 where not exists(select 1 from public.financial_evidence_links where financial_event_id=v_event and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000') and coalesce(evidence_reference,'')=coalesce(p_source_reference,''));
 return v_event;
end $$;

revoke all on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) to authenticated;

create or replace function public.refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid(); v_org uuid; v_channel uuid; v_expected numeric; v_reported numeric; v_settled numeric; v_case uuid; v_status text;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id into v_channel from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 select coalesce(sum(amount),0) into v_expected from public.financial_events where organization_id=v_org and proposal_id=p_proposal_id and component_type is not distinct from p_component_type and event_type='commission_expected';
 select coalesce(sum(amount),0) into v_reported from public.financial_events where organization_id=v_org and proposal_id=p_proposal_id and component_type is not distinct from p_component_type and event_type='commission_reported';
 select coalesce(sum(amount),0) into v_settled from public.financial_events where organization_id=v_org and proposal_id=p_proposal_id and component_type is not distinct from p_component_type and event_type='payment_received';
 v_status:=case when v_expected=0 and (v_reported>0 or v_settled>0) then 'human_required' when v_settled=v_expected and v_expected>0 then 'matched' when v_reported<>v_expected or v_settled<>v_expected then 'divergent' else 'open' end;
 select id into v_case from public.financial_reconciliation_cases where organization_id=v_org and proposal_id=p_proposal_id and component_type is not distinct from p_component_type order by created_at limit 1;
 if v_case is null then
  insert into public.financial_reconciliation_cases(organization_id,proposal_id,channel_id,component_type,expected_amount,reported_amount,settled_amount,status)
  values(v_org,p_proposal_id,v_channel,p_component_type,v_expected,v_reported,v_settled,v_status) returning id into v_case;
 else
  update public.financial_reconciliation_cases set expected_amount=v_expected,reported_amount=v_reported,settled_amount=v_settled,status=v_status,updated_at=now() where id=v_case;
 end if;
 return v_case;
end $$;
revoke all on function public.refresh_financial_reconciliation(uuid,text) from public,anon;
grant execute on function public.refresh_financial_reconciliation(uuid,text) to authenticated;
