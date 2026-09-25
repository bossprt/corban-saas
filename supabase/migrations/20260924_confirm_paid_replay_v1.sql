-- PREPARED, NOT APPLIED. Forward-only replacement of public.confirm_proposal_paid_from_import (defined by LIVE column_security_and_tenant_derivation_v1).
-- Finding: replaying the confirmation of an already confirmed decision failed with 'proposal_must_be_approved' because the status check ran
-- before the idempotency lookup, so a retried request (double click, retried worker) surfaced as an error instead of returning the existing
-- evidence. Everything else is unchanged: same authorization, same evidence requirements, SECURITY INVOKER, same paid-evidence token.
create or replace function public.confirm_proposal_paid_from_import(p_decision_id uuid)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_org uuid;v_batch uuid;v_candidate uuid;v_proposal uuid;v_row uuid;v_kind text;v_payload jsonb;v_semantic text;v_raw_status text;v_at timestamptz;v_id uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;
 select c.proposal_id,c.normalized_row_id into v_proposal,v_row from public.import_match_candidates c where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null;
 if v_proposal is null then raise exception 'exact_status_proposal_match_required'; end if;
 -- replay: this exact decision was already confirmed; return its evidence (nothing is written again)
 select e.id into v_id from public.proposal_status_evidence e where e.organization_id=v_org and e.import_decision_id=p_decision_id and e.canonical_status='paid';
 if v_id is not null then return v_id; end if;
 select e.record_kind,e.normalized_payload into v_kind,v_payload from private.import_row_evidence(v_row) e;
 if v_kind is distinct from 'status' then raise exception 'exact_status_proposal_match_required'; end if;
 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 if v_semantic<>'production_report' then raise exception 'production_report_required'; end if;
 if lower(coalesce(v_payload->>'canonicalStatus',''))<>'paid' then raise exception 'paid_status_evidence_required'; end if;
 v_raw_status:=nullif(v_payload->>'rawStatus','');v_at:=nullif(v_payload->>'occurredAt','')::timestamptz;
 if v_raw_status is null or v_at is null then raise exception 'status_evidence_details_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=v_proposal and organization_id=v_org and status='approved') then raise exception 'proposal_must_be_approved'; end if;
 insert into public.proposal_status_evidence(organization_id,proposal_id,import_decision_id,canonical_status,raw_status,evidenced_at,created_by)
 values(v_org,v_proposal,p_decision_id,'paid',v_raw_status,v_at,auth.uid()) on conflict(organization_id,import_decision_id,canonical_status) do nothing returning id into v_id;
 if v_id is null then select id into v_id from public.proposal_status_evidence where organization_id=v_org and import_decision_id=p_decision_id and canonical_status='paid'; end if;
 perform set_config('corban.paid_evidence_rpc','on',true);
 update public.proposals_v2 set status='paid',updated_at=now() where id=v_proposal and organization_id=v_org;
 perform set_config('corban.paid_evidence_rpc','off',true);
 return v_id;
end $function$;
