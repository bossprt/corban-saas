-- PREPARED, NOT APPLIED (Human Gate: new financial-publication DDL).
-- Closes defects found by adversarial review of the live ledger (2026-09-18/19):
--  1. refresh_financial_reconciliation ADDED reversal/adjustment amounts (amount >= 0 by CHECK) and relied on
--     metadata->>'affects', so a reversal of a received payment INCREASED settled instead of decreasing it.
--  2. reversal/adjustment/expected events could be inserted directly by any supervisor+ with no link validation.
--  3. Organization was resolved with `organization_memberships ... limit 1` (ambiguous for multi-tenant users).
--     The new functions derive the tenant from the RESOURCE (event/proposal) and then require membership there.
-- Model: a reversal is an append-only compensating event referencing the original. Multiple PARTIAL reversals of
-- one event are allowed; their cumulative sum can never exceed the original amount. Concurrency is serialized per
-- original event with a transaction-scoped advisory lock taken BEFORE the cumulative sum is read (READ COMMITTED
-- re-reads committed rows per statement; other isolation levels are rejected). History is never updated/deleted.
-- Adjustments have no governed publisher yet, so they stay blocked (fail closed).

-- 1. Guard: every financial event type must arrive through its governed publisher.
create or replace function public.guard_financial_event_insert()
returns trigger language plpgsql set search_path=public as $$
declare o record; v_already numeric;
begin
 if new.event_type in ('commission_reported','payment_received','downstream_paid') then
  if current_setting('corban.financial_evidence_rpc',true) is distinct from 'on' then raise exception 'financial_fact_requires_evidence_rpc'; end if;
 elsif new.event_type='commission_expected' then
  if current_setting('corban.financial_expected_rpc',true) is distinct from 'on' then raise exception 'expected_commission_requires_governed_rpc'; end if;
 elsif new.event_type='reversal' then
  if current_setting('corban.financial_reversal_rpc',true) is distinct from 'on' then raise exception 'financial_reversal_requires_governed_rpc'; end if;
  if current_setting('transaction_isolation') is distinct from 'read committed' then raise exception 'reversal_requires_read_committed'; end if;
  -- Serialize concurrent reversals of the same original BEFORE reading the cumulative total.
  perform pg_advisory_xact_lock(hashtextextended('financial_reversal:'||new.reverses_event_id::text,0));
  select * into o from public.financial_events where id=new.reverses_event_id;
  if not found then raise exception 'reversed_event_not_found'; end if;
  if o.organization_id<>new.organization_id or o.proposal_id is distinct from new.proposal_id or o.component_type is distinct from new.component_type or o.currency<>new.currency then
   raise exception 'reversal_target_mismatch';
  end if;
  if o.event_type in ('reversal','adjustment') then raise exception 'cannot_reverse_a_reversal_or_adjustment'; end if;
  if new.amount<=0 then raise exception 'invalid_reversal_amount'; end if;
  select coalesce(sum(amount),0) into v_already from public.financial_events where reverses_event_id=o.id and event_type='reversal';
  if v_already+new.amount>o.amount then raise exception 'reversal_exceeds_original'; end if;
 else
  -- adjustment, network_share_expected, bonus_expected, downstream_payable: no governed publisher exists yet.
  raise exception 'financial_event_type_not_governed';
 end if;
 return new;
end $$;
revoke all on function public.guard_financial_event_insert() from public,anon,authenticated;

-- 2. Governed reversal publisher. Tenant comes from the reversed event (RLS-scoped read), never from LIMIT 1.
create or replace function public.publish_financial_reversal(p_event_id uuid,p_amount numeric,p_reason text,p_source_kind text,p_source_reference text)
returns uuid language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();o public.financial_events%rowtype;v_key text;v_event uuid;v_already numeric;
begin
 if v_user is null then raise exception 'forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('financial_reversal:'||p_event_id::text,0));
 select * into o from public.financial_events where id=p_event_id;
 if not found then raise exception 'event_not_found'; end if;
 if not public.has_active_organization_role(o.organization_id,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'reversal_reason_required'; end if;
 -- Source 'import' is excluded: this RPC carries no batch/row lineage to validate it.
 if p_source_kind is null or p_source_kind not in ('bank_report','partner_report','payment_evidence','manual_review') then raise exception 'reversal_source_required'; end if;
 if nullif(trim(p_source_reference),'') is null then raise exception 'reversal_reference_required'; end if;
 if o.event_type in ('reversal','adjustment') then raise exception 'cannot_reverse_a_reversal_or_adjustment'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'invalid_reversal_amount'; end if;
 v_key:='reversal:'||o.id::text||':'||encode(extensions.digest(concat_ws('|',p_amount::text,p_source_kind,p_source_reference),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=o.organization_id and idempotency_key=v_key;
 if v_event is not null then return v_event; end if;
 select coalesce(sum(amount),0) into v_already from public.financial_events where reverses_event_id=o.id and event_type='reversal';
 if v_already+p_amount>o.amount then raise exception 'reversal_exceeds_original'; end if;
 perform set_config('corban.financial_reversal_rpc','on',true);
 insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,reverses_event_id,metadata,created_by)
 values(o.organization_id,o.proposal_id,o.channel_id,o.producer_entity_id,o.payer_entity_id,'reversal',o.component_type,p_amount,o.currency,now(),v_key,p_source_kind,p_source_reference,o.id,jsonb_build_object('reason',p_reason,'reversed_event_type',o.event_type),v_user)
 returning id into v_event;
 perform set_config('corban.financial_reversal_rpc','off',true);
 if o.proposal_id is not null then perform public.refresh_financial_reconciliation(o.proposal_id,o.component_type); end if;
 return v_event;
end $$;
revoke all on function public.publish_financial_reversal(uuid,numeric,text,text,text) from public,anon;
grant execute on function public.publish_financial_reversal(uuid,numeric,text,text,text) to authenticated;

-- 3. Reconciliation: tenant from the proposal; reversals SUBTRACT from the bucket of the event they reverse.
create or replace function public.refresh_financial_reconciliation(p_proposal_id uuid,p_component_type text)
returns uuid language plpgsql set search_path=public as $$
declare v_org uuid;v_channel uuid;v_expected numeric;v_reported numeric;v_settled numeric;v_case uuid;v_status text;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null then raise exception 'proposal_not_found'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 -- Serialize refreshes per proposal/component so a stale aggregate can never overwrite a newer one.
 perform pg_advisory_xact_lock(hashtextextended('financial_refresh:'||p_proposal_id::text||':'||coalesce(p_component_type,'__none__'),0));
 select channel_id into v_channel from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 select coalesce(sum(case when e.event_type='commission_expected' then e.amount
                          when e.event_type='reversal' and r.event_type='commission_expected' then -e.amount else 0 end),0),
        coalesce(sum(case when e.event_type='commission_reported' then e.amount
                          when e.event_type='reversal' and r.event_type='commission_reported' then -e.amount else 0 end),0),
        coalesce(sum(case when e.event_type='payment_received' then e.amount
                          when e.event_type='reversal' and r.event_type='payment_received' then -e.amount else 0 end),0)
 into v_expected,v_reported,v_settled
 from public.financial_events e left join public.financial_events r on r.id=e.reverses_event_id
 where e.organization_id=v_org and e.proposal_id=p_proposal_id and e.component_type is not distinct from p_component_type;
 if v_expected<0 or v_reported<0 or v_settled<0 then raise exception 'reconciliation_negative_balance'; end if;
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

-- 4. Expected-commission publisher: same logic as live, but tenant derived from the proposal and the guard
--    token set only around the insert so direct commission_expected inserts are rejected.
create or replace function public.publish_expected_commission(p_proposal_id uuid)
returns integer language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_snap public.proposal_commercial_snapshots%rowtype;v_cs public.proposal_commercial_component_snapshots%rowtype;v_base numeric;v_gross numeric;v_tenant numeric;v_count integer:=0;v_rows integer;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 select * into v_snap from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
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
