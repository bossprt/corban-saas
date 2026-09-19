-- PREPARED, NOT APPLIED (Human Gate: production privilege change + replaces 10 live functions). Forward-only.
-- Two closely coupled goals, one migration because the column revokes break the old function bodies:
--
-- A. COLUMN SECURITY. `authenticated` is ONE database role for every app role, so column grants cannot tell an agent from a
--    supervisor. Mixed tables therefore expose the operational columns directly (column-level SELECT) and serve the economic
--    columns only through narrow SECURITY DEFINER readers that live in the non-exposed `private` schema and enforce
--    membership + supervisor+ inside (public entry points are SECURITY INVOKER wrappers).
--      import_normalized_rows: restricted = commission_upfront, commission_deferred, amount, normalized_payload
--      proposal_commercial_snapshots: restricted = commission_rule_version_id, split_rule_version_id, snapshot
--    Not changed (business decision needed, see docs/audits): proposals_v2.expected_commission_amount / commercial_snapshot,
--    simulations.expected_commission_amount / result_snapshot, contracts.commission_percentage (legacy).
--
-- B/C. TENANT DERIVED FROM THE RESOURCE. Every function below used `organization_memberships ... limit 1`. Each now derives the
--    organization from the resource it operates on (decision, source, proposal, channel, relationship, row) and only then
--    requires an ACTIVE membership / role in THAT organization. A user in several organizations is never resolved arbitrarily.
--    create_customer_with_timeline has no resource, so it takes an explicit p_organization_id validated against membership.
--    Coherent rule for product_table_external_identities: catalog configuration = manager+ (matches its RLS policy), so
--    apply_approved_import_match now requires manager+ for the table-identity path (supervisor keeps proposal identities).

-- ============ A. column-level privileges ============
revoke select on table public.import_normalized_rows from authenticated;
grant select (id,organization_id,raw_row_id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,normalization_version,created_at)
 on table public.import_normalized_rows to authenticated;

revoke select on table public.proposal_commercial_snapshots from authenticated;
grant select (proposal_id,organization_id,channel_id,producer_entity_id,payer_entity_id,created_at)
 on table public.proposal_commercial_snapshots to authenticated;

create schema if not exists private;
revoke all on schema private from public,anon;
grant usage on schema private to authenticated;

-- membership/role check shared by the private readers (callers MUST coalesce: a NULL role makes `not in` NULL, not true); tenant comes from the caller-supplied RESOURCE organization
create or replace function private.caller_role_in(p_org uuid)
returns text language sql stable security definer set search_path='' as $$
 select m.role from public.organization_memberships m where m.organization_id=p_org and m.user_id=(select auth.uid()) and m.status='active' limit 1
$$;
revoke all on function private.caller_role_in(uuid) from public,anon;
grant execute on function private.caller_role_in(uuid) to authenticated;
-- (limit 1 above is safe: (organization_id,user_id) identifies at most one active membership row per organization)

create or replace function private.list_import_rows(p_batch_id uuid,p_numbers text[] default null)
returns table(id uuid,organization_id uuid,raw_row_id uuid,batch_id uuid,source_id uuid,row_number integer,record_kind text,bank_key text,external_proposal_number text,producer_tax_id text,external_table_code text,external_table_name text,operation_type text,term integer,rate numeric,normalization_version text,commission_upfront numeric,commission_deferred numeric,amount numeric,normalized_payload jsonb)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;v_role text;v_priv boolean;
begin
 select b.organization_id into v_org from public.import_batches b where b.id=p_batch_id;
 v_role:=case when v_org is null then null else private.caller_role_in(v_org) end;
 if v_role is null then raise exception 'batch_not_found_or_forbidden'; end if;
 v_priv:=v_role in ('admin','manager','supervisor');
 return query
  select n.id,n.organization_id,n.raw_row_id,rr.batch_id,b.source_id,rr.row_number,n.record_kind,n.bank_key,n.external_proposal_number,n.producer_tax_id,n.external_table_code,n.external_table_name,n.operation_type,n.term,n.rate,n.normalization_version,
   case when v_priv then n.commission_upfront end,case when v_priv then n.commission_deferred end,case when v_priv then n.amount end,case when v_priv then n.normalized_payload end
  from public.import_normalized_rows n
  join public.import_raw_rows rr on rr.id=n.raw_row_id and rr.organization_id=n.organization_id
  join public.import_batches b on b.id=rr.batch_id and b.organization_id=rr.organization_id
  where n.organization_id=v_org
    and ((p_numbers is null and rr.batch_id=p_batch_id) or (p_numbers is not null and n.external_proposal_number=any(p_numbers)))
  order by rr.row_number,n.id
  limit 500;
end $$;
revoke all on function private.list_import_rows(uuid,text[]) from public,anon;
grant execute on function private.list_import_rows(uuid,text[]) to authenticated;

create or replace function public.list_import_rows(p_batch_id uuid,p_numbers text[] default null)
returns table(id uuid,organization_id uuid,raw_row_id uuid,batch_id uuid,source_id uuid,row_number integer,record_kind text,bank_key text,external_proposal_number text,producer_tax_id text,external_table_code text,external_table_name text,operation_type text,term integer,rate numeric,normalization_version text,commission_upfront numeric,commission_deferred numeric,amount numeric,normalized_payload jsonb)
language sql stable security invoker set search_path='' as $$ select * from private.list_import_rows(p_batch_id,p_numbers) $$;
revoke all on function public.list_import_rows(uuid,text[]) from public,anon;
grant execute on function public.list_import_rows(uuid,text[]) to authenticated;

-- economic evidence of ONE normalized row, supervisor+ of the row's organization only
create or replace function private.import_row_evidence(p_row_id uuid)
returns table(record_kind text,amount numeric,normalized_payload jsonb)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
 select n.organization_id into v_org from public.import_normalized_rows n where n.id=p_row_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select n.record_kind,n.amount,n.normalized_payload from public.import_normalized_rows n where n.id=p_row_id and n.organization_id=v_org;
end $$;
revoke all on function private.import_row_evidence(uuid) from public,anon;
grant execute on function private.import_row_evidence(uuid) to authenticated;

-- frozen commercial route economics of ONE proposal, supervisor+ only
create or replace function private.commercial_route(p_proposal_id uuid)
returns table(proposal_id uuid,channel_id uuid,producer_entity_id uuid,payer_entity_id uuid,commission_rule_version_id uuid,split_rule_version_id uuid,snapshot jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare v_org uuid;
begin
 select p.organization_id into v_org from public.proposals_v2 p where p.id=p_proposal_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select s.proposal_id,s.channel_id,s.producer_entity_id,s.payer_entity_id,s.commission_rule_version_id,s.split_rule_version_id,s.snapshot,s.created_at
  from public.proposal_commercial_snapshots s where s.proposal_id=p_proposal_id and s.organization_id=v_org;
end $$;
revoke all on function private.commercial_route(uuid) from public,anon;
grant execute on function private.commercial_route(uuid) to authenticated;

create or replace function public.get_commercial_route(p_proposal_id uuid)
returns table(proposal_id uuid,channel_id uuid,producer_entity_id uuid,payer_entity_id uuid,commission_rule_version_id uuid,split_rule_version_id uuid,snapshot jsonb,created_at timestamptz)
language sql stable security invoker set search_path='' as $$ select * from private.commercial_route(p_proposal_id) $$;
revoke all on function public.get_commercial_route(uuid) from public,anon;
grant execute on function public.get_commercial_route(uuid) to authenticated;

-- ============ functions that read restricted columns (explicit columns / private readers) ============
create or replace function public.generate_import_match_candidates(p_batch_id uuid)
 returns integer language plpgsql set search_path to 'public' as $function$
declare v_org uuid;v_count integer:=0;r record;v_proposal uuid;v_proposal_count integer;v_table uuid;v_table_count integer;v_channel uuid;
begin
 select b.organization_id into v_org from public.import_batches b where b.id=p_batch_id and public.is_active_organization_member(b.organization_id);
 if v_org is null then raise exception 'batch_not_found_or_forbidden'; end if;
 perform set_config('corban.import_match_rpc','on',true);
 for r in select n.id,n.external_proposal_number,n.bank_key,n.external_table_code from public.import_normalized_rows n join public.import_raw_rows rr on rr.id=n.raw_row_id and rr.organization_id=n.organization_id where rr.batch_id=p_batch_id and n.organization_id=v_org
 loop
  if exists(select 1 from public.import_match_candidates c where c.organization_id=v_org and c.normalized_row_id=r.id) then continue; end if;
  v_proposal:=null;v_proposal_count:=0;v_table:=null;v_table_count:=0;v_channel:=null;
  if r.external_proposal_number is not null then
   select count(*),(array_agg(e.proposal_id))[1] into v_proposal_count,v_proposal from public.proposal_external_identities e
   where e.organization_id=v_org and e.external_proposal_number=r.external_proposal_number and (r.bank_key is null or lower(e.institution_key)=lower(r.bank_key));
  end if;
  if r.external_table_code is not null then
   select count(*),(array_agg(e.product_table_id))[1],(array_agg(e.channel_id))[1] into v_table_count,v_table,v_channel from public.product_table_external_identities e
   where e.organization_id=v_org and e.external_code=r.external_table_code and (e.effective_until is null or e.effective_until>now());
  end if;
  if v_proposal_count=1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,proposal_id,product_table_id,channel_id,match_strength,match_basis,status)
   values(v_org,r.id,v_proposal,case when v_table_count=1 then v_table end,case when v_table_count=1 then v_channel end,'exact',jsonb_build_object('external_proposal_number',r.external_proposal_number,'bank_key',r.bank_key,'proposal_matches',v_proposal_count,'table_matches',v_table_count),'suggested');
  elsif v_proposal_count>1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status) values(v_org,r.id,'ambiguous',jsonb_build_object('external_proposal_number',r.external_proposal_number,'proposal_matches',v_proposal_count),'human_required');
  elsif v_table_count=1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,product_table_id,channel_id,match_strength,match_basis,status) values(v_org,r.id,v_table,v_channel,'strong',jsonb_build_object('external_table_code',r.external_table_code,'table_matches',1),'suggested');
  elsif v_table_count>1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status) values(v_org,r.id,'ambiguous',jsonb_build_object('external_table_code',r.external_table_code,'table_matches',v_table_count),'human_required');
  else
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status) values(v_org,r.id,'none',jsonb_build_object('external_proposal_number',r.external_proposal_number,'external_table_code',r.external_table_code),'human_required');
  end if;
  v_count:=v_count+1;
 end loop;
 perform set_config('corban.import_match_rpc','off',true);
 update public.import_batches set status='ready_for_review',completed_at=coalesce(completed_at,now()) where id=p_batch_id and organization_id=v_org;
 return v_count;
end $function$;

-- tenant = the DECISION's organization; table identities (catalog) need manager+, proposal identities supervisor+
create or replace function public.apply_approved_import_match(p_decision_id uuid)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare
 v_org uuid; v_user uuid:=auth.uid(); v_decision public.import_decisions%rowtype;
 v_candidate public.import_match_candidates%rowtype; v_row record;
 v_applied uuid; v_proposal_identity uuid; v_table_identity uuid; v_existing_target uuid; v_latest uuid;
begin
 select * into v_decision from public.import_decisions where id=p_decision_id;
 if not found or v_decision.decision<>'approve' or v_decision.candidate_id is null then raise exception 'approved_decision_required'; end if;
 v_org:=v_decision.organization_id;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_required'; end if;
 select id into v_latest from public.import_decisions where organization_id=v_org and candidate_id=v_decision.candidate_id order by decided_at desc,id desc limit 1;
 if v_latest is distinct from p_decision_id then raise exception 'superseded_decision'; end if;
 select id into v_applied from public.import_applied_decisions where organization_id=v_org and decision_id=p_decision_id;
 if v_applied is not null then return v_applied; end if;
 select * into v_candidate from public.import_match_candidates where id=v_decision.candidate_id and organization_id=v_org and normalized_row_id=v_decision.normalized_row_id;
 if not found or v_candidate.match_strength not in ('exact','strong') then raise exception 'strong_match_required'; end if;
 select id,bank_key,external_proposal_number,external_table_code,external_table_name into v_row from public.import_normalized_rows where id=v_decision.normalized_row_id and organization_id=v_org;
 if not found then raise exception 'normalized_row_missing'; end if;
 if v_candidate.proposal_id is not null then
  if not exists(select 1 from public.proposals_v2 where id=v_candidate.proposal_id and organization_id=v_org) then raise exception 'proposal_tenant_mismatch'; end if;
  if v_candidate.channel_id is not null and not exists(select 1 from public.commercial_channels where id=v_candidate.channel_id and organization_id=v_org) then raise exception 'channel_tenant_mismatch'; end if;
  if v_row.external_proposal_number is null or v_row.bank_key is null then raise exception 'proposal_identity_incomplete'; end if;
  select id,proposal_id into v_proposal_identity,v_existing_target from public.proposal_external_identities where organization_id=v_org and lower(institution_key)=lower(v_row.bank_key) and external_proposal_number=v_row.external_proposal_number;
  if v_proposal_identity is not null and v_existing_target is distinct from v_candidate.proposal_id then raise exception 'proposal_identity_conflict'; end if;
  if v_proposal_identity is null then
   insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number,channel_id,source,metadata)
   values(v_org,v_candidate.proposal_id,lower(v_row.bank_key),v_row.external_proposal_number,v_candidate.channel_id,'import_reconciliation',jsonb_build_object('decision_id',p_decision_id,'normalized_row_id',v_row.id))
   returning id into v_proposal_identity;
  end if;
 end if;
 if v_candidate.product_table_id is not null then
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'table_identity_requires_manager'; end if;
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
end $function$;

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

create or replace function public.publish_financial_fact_from_import_decision(p_decision_id uuid)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_org uuid;v_batch uuid;v_raw uuid;v_row uuid;v_proposal uuid;v_semantic text;v_event_type text;v_amount numeric;v_payload jsonb;v_component text;v_occurred timestamptz;v_ref text;v_candidate uuid;v_event uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;
 select c.proposal_id,c.normalized_row_id into v_proposal,v_row from public.import_match_candidates c where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null;
 if v_proposal is null then raise exception 'exact_proposal_match_required'; end if;
 select n.raw_row_id into v_raw from public.import_normalized_rows n where n.id=v_row and n.organization_id=v_org;
 select e.amount,e.normalized_payload into v_amount,v_payload from private.import_row_evidence(v_row) e;
 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 v_event_type:=case v_semantic when 'commission_statement' then 'commission_reported' when 'payment_statement' then 'payment_received' when 'network_payment_statement' then 'downstream_paid' else null end;
 if v_event_type is null then raise exception 'source_does_not_prove_financial_fact'; end if;
 if v_amount is null or v_amount<0 then raise exception 'valid_amount_required'; end if;
 v_component:=coalesce(nullif(v_payload->>'componentType',''),'upfront');v_occurred:=nullif(v_payload->>'occurredAt','')::timestamptz;
 if v_occurred is null then raise exception 'financial_fact_date_required'; end if;
 v_ref:='import-decision:'||p_decision_id::text;
 v_event:=public.publish_financial_evidence_event(v_proposal,v_event_type,v_component,v_amount,v_occurred,'import',v_ref,v_batch,v_raw,p_decision_id);
 perform public.refresh_financial_reconciliation(v_proposal,v_component);
 return v_event;
end $function$;

create or replace function public.publish_expected_commission(p_proposal_id uuid)
returns integer language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_snap record;v_cs public.proposal_commercial_component_snapshots%rowtype;v_base numeric;v_gross numeric;v_tenant numeric;v_count integer:=0;v_rows integer;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 select r.* into v_snap from private.commercial_route(p_proposal_id) r;
 if not found or v_snap.commission_rule_version_id is null then raise exception 'frozen_commercial_snapshot_required'; end if;
 v_base:=nullif(v_snap.snapshot->>'calculation_base_amount','')::numeric;
 if v_base is null or v_base<0 then raise exception 'snapshot_calculation_base_required'; end if;
 if not exists(select 1 from public.proposal_commercial_component_snapshots where proposal_id=p_proposal_id and organization_id=v_org) then raise exception 'per_component_snapshot_required'; end if;
 for v_cs in select * from public.proposal_commercial_component_snapshots where proposal_id=p_proposal_id and organization_id=v_org order by id loop
  if v_cs.gross_percentage is null and v_cs.fixed_amount is null then raise exception 'component_value_required'; end if;
  v_gross:=coalesce(v_cs.fixed_amount,v_base*v_cs.gross_percentage/100);
  if v_cs.component_type='deferred_anticipation' then if v_cs.anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;v_gross:=v_gross*v_cs.anticipation_factor;end if;
  v_tenant:=v_gross*v_cs.upstream_share;
  perform set_config('corban.financial_expected_rpc','on',true);
  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_snap.channel_id,v_snap.producer_entity_id,v_snap.payer_entity_id,'commission_expected',v_cs.component_type,v_tenant,'BRL',now(),
  'expected:'||p_proposal_id::text||':'||v_cs.commission_component_id::text||':'||coalesce(v_cs.split_rule_version_id::text,'none'),
  'proposal_snapshot',p_proposal_id::text,jsonb_build_object('gross_amount',v_gross,'tenant_amount',v_tenant,'calculation_base',v_base,'upstream_share',v_cs.upstream_share,'downstream_share',v_cs.downstream_share,'split_rule_version_id',v_cs.split_rule_version_id),v_user)
  on conflict(organization_id,idempotency_key) do nothing;
  get diagnostics v_rows=row_count;
  perform set_config('corban.financial_expected_rpc','off',true);
  v_count:=v_count+v_rows;
 end loop;
 return v_count;
end $$;

-- ============ B/C. tenant derived from the resource (no `limit 1` membership resolution) ============
create or replace function public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_user uuid:=auth.uid();v_org uuid;v_batch uuid;v_item jsonb;v_raw uuid;v_n jsonb;v_row_no int;
begin
 -- tenant = the SOURCE's organization (RLS only shows sources of organizations the caller belongs to)
 select s.organization_id into v_org from public.import_sources s where s.id=p_source_id and s.is_active;
 if v_org is null or not public.is_active_organization_member(v_org) then raise exception 'source_not_found'; end if;
 if p_content_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'invalid_sha256'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'rows_required'; end if;
 select id into v_batch from public.import_batches where organization_id=v_org and content_sha256=p_content_sha256;
 if v_batch is not null then return v_batch; end if;
 insert into public.import_batches(organization_id,source_id,original_filename,content_sha256,mime_type,parser_key,parser_version,status,row_count,received_by,completed_at)
 values(v_org,p_source_id,p_original_filename,p_content_sha256,p_mime_type,p_parser_key,p_parser_version,'ready_for_review',jsonb_array_length(p_rows),v_user,now()) returning id into v_batch;
 for v_item in select value from jsonb_array_elements(p_rows) loop
  v_row_no:=(v_item->>'rowNumber')::int; v_n:=v_item->'normalized';
  if v_row_no<1 or jsonb_typeof(v_item->'rawPayload')<>'object' or jsonb_typeof(v_n)<>'object' then raise exception 'invalid_row_payload'; end if;
  insert into public.import_raw_rows(organization_id,batch_id,row_number,raw_payload,raw_hash)
  values(v_org,v_batch,v_row_no,v_item->'rawPayload',encode(extensions.digest((v_item->'rawPayload')::text,'sha256'),'hex')) returning id into v_raw;
  insert into public.import_normalized_rows(organization_id,raw_row_id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,commission_upfront,commission_deferred,amount,normalized_payload,normalization_version)
  values(v_org,v_raw,v_n->>'recordKind',nullif(v_n->>'bankKey',''),nullif(v_n->>'externalProposalNumber',''),nullif(v_n->>'producerTaxId',''),nullif(v_n->>'externalTableCode',''),nullif(v_n->>'externalTableName',''),nullif(v_n->>'operationType',''),nullif(v_n->>'term','')::int,nullif(v_n->>'rate','')::numeric,nullif(v_n->>'commissionUpfront','')::numeric,nullif(v_n->>'commissionDeferred','')::numeric,nullif(v_n->>'amount','')::numeric,coalesce(v_n->'normalizedPayload','{}'::jsonb),p_parser_version);
 end loop;
 return v_batch;
end $function$;

create or replace function public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid default null::uuid, p_import_raw_row_id uuid default null::uuid, p_import_decision_id uuid default null::uuid)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_user uuid:=auth.uid();v_org uuid;v_event uuid;v_channel uuid;v_producer uuid;v_payer uuid;v_key text;v_semantic text;v_raw_batch uuid;v_decision_batch uuid;
begin
 -- tenant = the PROPOSAL's organization
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence') then raise exception 'confirmed_evidence_source_required'; end if;
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
 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||encode(extensions.digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');
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
end $function$;

create or replace function public.create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text default null::text)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_org uuid;v_id uuid;v_version int;
begin
 -- tenant = the CHANNEL's organization
 select organization_id into v_org from public.commercial_channels where id=p_channel_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'channel_not_found'; end if;
 if not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 if p_percentage is null and p_fixed_amount is null then raise exception 'component_value_required'; end if;
 if p_component_type='deferred_anticipation' and p_anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
 select coalesce(max(version),0)+1 into v_version from public.channel_commission_rule_versions where organization_id=v_org and channel_id=p_channel_id and product_table_id=p_product_table_id;
 insert into public.channel_commission_rule_versions(organization_id,channel_id,product_table_id,version,status,operation_type,effective_from,published_at)
 values(v_org,p_channel_id,p_product_table_id,v_version,'published',p_operation_type,p_effective_from,now()) returning id into v_id;
 insert into public.commission_rule_components(organization_id,rule_version_id,component_type,percentage,fixed_amount,anticipation_factor,calculation_base)
 values(v_org,v_id,p_component_type,p_percentage,p_fixed_amount,p_anticipation_factor,p_calculation_base);
 return v_id;
end $function$;

create or replace function public.create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone)
 returns uuid language plpgsql set search_path to 'public' as $function$
declare v_org uuid;v_id uuid;v_version int;
begin
 -- tenant = the RELATIONSHIP's organization
 select organization_id into v_org from public.commercial_relationships where id=p_relationship_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'relationship_not_found'; end if;
 if p_downstream_share<0 or p_downstream_share>1 then raise exception 'invalid_share'; end if;
 if p_product_table_id is not null and not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 select coalesce(max(version),0)+1 into v_version from public.network_split_rule_versions where organization_id=v_org and relationship_id=p_relationship_id and product_table_id is not distinct from p_product_table_id and component_type is not distinct from p_component_type;
 insert into public.network_split_rule_versions(organization_id,relationship_id,bank_id,product_table_id,component_type,version,downstream_share,upstream_share,payment_flow,effective_from,status)
 values(v_org,p_relationship_id,p_bank_id,p_product_table_id,p_component_type,v_version,p_downstream_share,1-p_downstream_share,p_payment_flow,p_effective_from,'published') returning id into v_id;
 return v_id;
end $function$;

-- No resource exists for a new customer: the organization is EXPLICIT and validated against an active membership.
create or replace function public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text default null, p_email text default null, p_original_source text default 'corban_os')
 returns uuid language plpgsql set search_path to '' as $function$
declare v_customer_id uuid;
begin
 if p_organization_id is null or not public.is_active_organization_member(p_organization_id) then raise exception 'active_membership_required'; end if;
 if nullif(btrim(p_full_name),'') is null then raise exception 'full_name_required'; end if;
 if p_cpf !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
 insert into public.clients(organization_id,full_name,cpf,phone,email,original_source)
 values(p_organization_id,btrim(p_full_name),p_cpf,nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),p_original_source) returning id into v_customer_id;
 insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id)
 values(p_organization_id,v_customer_id,'customer.created','corban_os',(select auth.uid()));
 return v_customer_id;
end $function$;
revoke all on function public.create_customer_with_timeline(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.create_customer_with_timeline(uuid,text,text,text,text,text) to authenticated;

-- Legacy 5-argument form: only deterministic when the caller has exactly ONE active membership; otherwise it refuses
-- instead of picking an organization.
create or replace function public.create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text default null, p_email text default null, p_original_source text default 'corban_os')
 returns uuid language plpgsql set search_path to '' as $function$
declare v_orgs uuid[];
begin
 select array_agg(m.organization_id) into v_orgs from public.organization_memberships m where m.user_id=(select auth.uid()) and m.status='active';
 if v_orgs is null or cardinality(v_orgs)<>1 then raise exception 'organization_required'; end if;
 return public.create_customer_with_timeline(v_orgs[1],p_full_name,p_cpf,p_phone,p_email,p_original_source);
end $function$;
