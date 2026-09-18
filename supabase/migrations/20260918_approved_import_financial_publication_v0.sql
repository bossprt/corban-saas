-- CORBAN OS V2 — Approved Import Financial Publication V0
-- Only an approved+applied exact proposal match from a governed financial source can publish a fact.
create or replace function public.publish_financial_fact_from_import_decision(p_decision_id uuid)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_batch uuid;v_raw uuid;v_proposal uuid;v_semantic text;v_event_type text;v_amount numeric;v_component text;v_occurred timestamptz;v_ref text;v_candidate uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate
 from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;

 select c.proposal_id,n.amount,n.normalized_payload,n.raw_row_id into v_proposal,v_amount,v_component,v_raw
 from public.import_match_candidates c
 join public.import_normalized_rows n on n.id=c.normalized_row_id and n.organization_id=c.organization_id
 where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null;
 if v_proposal is null then raise exception 'exact_proposal_match_required'; end if;

 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 v_event_type:=case v_semantic when 'commission_statement' then 'commission_reported' when 'payment_statement' then 'payment_received' when 'network_payment_statement' then 'downstream_paid' else null end;
 if v_event_type is null then raise exception 'source_does_not_prove_financial_fact'; end if;
 if v_amount is null or v_amount<0 then raise exception 'valid_amount_required'; end if;

 select coalesce(nullif(n.normalized_payload->>'componentType',''),'upfront'),
        nullif(n.normalized_payload->>'occurredAt','')::timestamptz
 into v_component,v_occurred
 from public.import_normalized_rows n where n.raw_row_id=v_raw and n.organization_id=v_org order by n.created_at desc limit 1;
 if v_occurred is null then raise exception 'financial_fact_date_required'; end if;
 v_ref:='import-decision:'||p_decision_id::text;
 return public.publish_financial_evidence_event(v_proposal,v_event_type,v_component,v_amount,v_occurred,'import',v_ref,v_batch,v_raw,p_decision_id);
end $$;
revoke all on function public.publish_financial_fact_from_import_decision(uuid) from public,anon;
grant execute on function public.publish_financial_fact_from_import_decision(uuid) to authenticated;
