-- PREPARED, NOT APPLIED (Human Gate: new financial-publication DDL).
-- Closes two defects found by adversarial review of the live ledger (2026-09-18):
--  1. refresh_financial_reconciliation ADDED reversal/adjustment amounts (amount >= 0 by CHECK) and relied on
--     metadata->>'affects', so a reversal of a received payment INCREASED settled instead of decreasing it.
--  2. reversal/adjustment events could be inserted directly by any supervisor+ with no link validation
--     (same organization/proposal/component, single reversal, amount cap, no reversal of a reversal).
-- History is never deleted: a reversal is a compensating event referencing the original.

create unique index if not exists financial_events_single_reversal_uidx
 on public.financial_events(organization_id,reverses_event_id) where event_type='reversal';

create or replace function public.guard_financial_event_insert()
returns trigger language plpgsql set search_path=public as $$
declare o record; already numeric;
begin
 if new.event_type in ('commission_reported','payment_received','downstream_paid') then
  if current_setting('corban.financial_evidence_rpc',true) is distinct from 'on' then raise exception 'financial_fact_requires_evidence_rpc'; end if;
 end if;
 if new.event_type in ('reversal','adjustment') then
  if current_setting('corban.financial_reversal_rpc',true) is distinct from 'on' then raise exception 'financial_reversal_requires_governed_rpc'; end if;
 end if;
 if new.event_type='reversal' then
  select * into o from public.financial_events where id=new.reverses_event_id;
  if not found then raise exception 'reversed_event_not_found'; end if;
  if o.organization_id<>new.organization_id or o.proposal_id<>new.proposal_id or o.component_type is distinct from new.component_type or o.currency<>new.currency then
   raise exception 'reversal_target_mismatch';
  end if;
  if o.event_type in ('reversal','adjustment') then raise exception 'cannot_reverse_a_reversal_or_adjustment'; end if;
  select coalesce(sum(amount),0) into already from public.financial_events where reverses_event_id=o.id and event_type='reversal';
  if already+new.amount>o.amount then raise exception 'reversal_exceeds_original'; end if;
 end if;
 return new;
end $$;
revoke all on function public.guard_financial_event_insert() from public,anon,authenticated;

create or replace function public.publish_financial_reversal(p_event_id uuid,p_amount numeric,p_reason text,p_source_kind text,p_source_reference text)
returns uuid language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;o public.financial_events%rowtype;v_key text;v_event uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'reversal_reason_required'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence','manual_review') then raise exception 'reversal_source_required'; end if;
 if nullif(trim(p_source_reference),'') is null then raise exception 'reversal_reference_required'; end if;
 select * into o from public.financial_events where id=p_event_id and organization_id=v_org;
 if not found then raise exception 'event_not_found'; end if;
 if p_amount is null or p_amount<=0 or p_amount>o.amount then raise exception 'invalid_reversal_amount'; end if;
 v_key:='reversal:'||o.id::text||':'||encode(digest(concat_ws('|',p_amount::text,p_source_kind,p_source_reference),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is not null then return v_event; end if;
 perform set_config('corban.financial_reversal_rpc','on',true);
 insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,reverses_event_id,metadata,created_by)
 values(v_org,o.proposal_id,o.channel_id,o.producer_entity_id,o.payer_entity_id,'reversal',o.component_type,p_amount,o.currency,now(),v_key,p_source_kind,p_source_reference,o.id,jsonb_build_object('reason',p_reason,'reversed_event_type',o.event_type),v_user)
 returning id into v_event;
 perform set_config('corban.financial_reversal_rpc','off',true);
 perform public.refresh_financial_reconciliation(o.proposal_id,o.component_type);
 return v_event;
end $$;
revoke all on function public.publish_financial_reversal(uuid,numeric,text,text,text) from public,anon;
grant execute on function public.publish_financial_reversal(uuid,numeric,text,text,text) to authenticated;

create or replace function public.refresh_financial_reconciliation(p_proposal_id uuid,p_component_type text)
returns uuid language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_channel uuid;v_expected numeric;v_reported numeric;v_settled numeric;v_case uuid;v_status text;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id into v_channel from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 -- Reversals subtract from the bucket of the event they reverse; adjustments carry an explicit direction.
 select coalesce(sum(case
    when e.event_type='commission_expected' then e.amount
    when e.event_type='reversal' and r.event_type='commission_expected' then -e.amount
    when e.event_type='adjustment' and e.metadata->>'affects'='expected' then case when e.metadata->>'direction'='decrease' then -e.amount else e.amount end
    else 0 end),0),
        coalesce(sum(case
    when e.event_type='commission_reported' then e.amount
    when e.event_type='reversal' and r.event_type='commission_reported' then -e.amount
    when e.event_type='adjustment' and e.metadata->>'affects'='reported' then case when e.metadata->>'direction'='decrease' then -e.amount else e.amount end
    else 0 end),0),
        coalesce(sum(case
    when e.event_type='payment_received' then e.amount
    when e.event_type='reversal' and r.event_type='payment_received' then -e.amount
    when e.event_type='adjustment' and e.metadata->>'affects'='settled' then case when e.metadata->>'direction'='decrease' then -e.amount else e.amount end
    else 0 end),0)
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
