-- CORBAN OS V2 — Approved Import Match Corrective Hardening V0
-- Corrective patch to the already-authorized identity application path.
create or replace function public.apply_approved_import_match(p_decision_id uuid)
returns uuid language plpgsql security invoker set search_path=public as $$
declare
 v_org uuid; v_user uuid:=auth.uid(); v_decision public.import_decisions%rowtype;
 v_candidate public.import_match_candidates%rowtype; v_row public.import_normalized_rows%rowtype;
 v_applied uuid; v_proposal_identity uuid; v_table_identity uuid; v_existing_target uuid; v_latest uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 select * into v_decision from public.import_decisions where id=p_decision_id and organization_id=v_org;
 if not found or v_decision.decision<>'approve' or v_decision.candidate_id is null then raise exception 'approved_decision_required'; end if;
 select id into v_latest from public.import_decisions where organization_id=v_org and candidate_id=v_decision.candidate_id order by decided_at desc,id desc limit 1;
 if v_latest is distinct from p_decision_id then raise exception 'superseded_decision'; end if;
 select id into v_applied from public.import_applied_decisions where organization_id=v_org and decision_id=p_decision_id;
 if v_applied is not null then return v_applied; end if;
 select * into v_candidate from public.import_match_candidates where id=v_decision.candidate_id and organization_id=v_org and normalized_row_id=v_decision.normalized_row_id;
 if not found or v_candidate.match_strength not in ('exact','strong') then raise exception 'strong_match_required'; end if;
 select * into v_row from public.import_normalized_rows where id=v_decision.normalized_row_id and organization_id=v_org;
 if not found then raise exception 'normalized_row_missing'; end if;

 if v_candidate.proposal_id is not null then
  if not exists(select 1 from public.proposals_v2 where id=v_candidate.proposal_id and organization_id=v_org) then raise exception 'proposal_tenant_mismatch'; end if;
  if v_candidate.channel_id is not null and not exists(select 1 from public.commercial_channels where id=v_candidate.channel_id and organization_id=v_org) then raise exception 'channel_tenant_mismatch'; end if;
  if v_row.external_proposal_number is null or v_row.bank_key is null then raise exception 'proposal_identity_incomplete'; end if;
  select id,proposal_id into v_proposal_identity,v_existing_target from public.proposal_external_identities where organization_id=v_org and institution_key=v_row.bank_key and external_proposal_number=v_row.external_proposal_number;
  if v_proposal_identity is not null and v_existing_target is distinct from v_candidate.proposal_id then raise exception 'proposal_identity_conflict'; end if;
  if v_proposal_identity is null then
   insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number,channel_id,source,metadata)
   values(v_org,v_candidate.proposal_id,v_row.bank_key,v_row.external_proposal_number,v_candidate.channel_id,'import_reconciliation',jsonb_build_object('decision_id',p_decision_id,'normalized_row_id',v_row.id))
   returning id into v_proposal_identity;
  end if;
 end if;

 if v_candidate.product_table_id is not null then
  if not exists(select 1 from public.product_tables where id=v_candidate.product_table_id and organization_id=v_org) then raise exception 'table_tenant_mismatch'; end if;
  if v_candidate.channel_id is null or not exists(select 1 from public.commercial_channels where id=v_candidate.channel_id and organization_id=v_org) then raise exception 'channel_tenant_mismatch'; end if;
  if v_row.external_table_code is null then raise exception 'table_identity_incomplete'; end if;
  select id,product_table_id into v_table_identity,v_existing_target from public.product_table_external_identities where organization_id=v_org and channel_id=v_candidate.channel_id and external_code=v_row.external_table_code;
  if v_table_identity is not null and v_existing_target is distinct from v_candidate.product_table_id then raise exception 'table_identity_conflict'; end if;
  if v_table_identity is null then
   insert into public.product_table_external_identities(organization_id,product_table_id,channel_id,external_code,external_name,effective_from)
   values(v_org,v_candidate.product_table_id,v_candidate.channel_id,v_row.external_table_code,v_row.external_table_name,now()) returning id into v_table_identity;
  end if;
 end if;

 if v_proposal_identity is null and v_table_identity is null then raise exception 'canonical_target_required'; end if;
 insert into public.import_applied_decisions(organization_id,decision_id,proposal_external_identity_id,table_external_identity_id,applied_by)
 values(v_org,p_decision_id,v_proposal_identity,v_table_identity,v_user) returning id into v_applied;
 return v_applied;
end $$;
revoke all on function public.apply_approved_import_match(uuid) from public,anon;
grant execute on function public.apply_approved_import_match(uuid) to authenticated;
