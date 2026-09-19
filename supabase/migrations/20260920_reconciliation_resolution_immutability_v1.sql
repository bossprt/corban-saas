-- PREPARED, NOT APPLIED (Human Gate: replaces two live functions). Block D re-audit of the LIVE guard found gaps.
-- Live guard_reconciliation_case_write (reconciliation_cases_write_hardening_v1) protects amounts and status transitions but
-- when `status` does NOT change it lets a supervisor+ UPDATE resolution_note, resolved_by and resolved_at freely:
--   * rewrite the justification of an already resolved case,
--   * stamp resolved_by/resolved_at with another user (forged audit trail),
--   * write a note on an open case without resolving it.
-- Fix: the resolution triple only changes together with the open -> resolved transition, is stamped from the session, and is
-- immutable afterwards. Also: refresh_financial_reconciliation used to overwrite `status` of a RESOLVED case with the derived
-- status, leaving resolved_by/resolved_at/note attached to an "open" case. A resolved case now stays resolved (amounts still
-- refresh; the UI flags cases whose amounts changed after resolution), so the audit trail is never orphaned.
create or replace function public.guard_reconciliation_case_write()
returns trigger language plpgsql set search_path to 'public' as $function$
begin
 if current_setting('corban.reconciliation_rpc',true)='on' then return new; end if;
 if tg_op='INSERT' then raise exception 'reconciliation_case_requires_governed_rpc'; end if;
 if new.organization_id is distinct from old.organization_id or new.proposal_id is distinct from old.proposal_id or new.channel_id is distinct from old.channel_id or new.component_type is distinct from old.component_type or new.expected_amount is distinct from old.expected_amount or new.reported_amount is distinct from old.reported_amount or new.settled_amount is distinct from old.settled_amount then raise exception 'reconciliation_amounts_are_derived'; end if;
 if old.status='resolved' and (new.status is distinct from old.status or new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at) then
  raise exception 'reconciliation_resolution_is_immutable';
 end if;
 if new.status is distinct from old.status then
  if new.status<>'resolved' then raise exception 'reconciliation_status_is_derived'; end if;
  if nullif(btrim(new.resolution_note),'') is null then raise exception 'resolution_note_required'; end if;
  if length(btrim(new.resolution_note))<10 or length(btrim(new.resolution_note))>2000 then raise exception 'resolution_note_length_invalid'; end if;
  new.resolved_by:=(select auth.uid()); new.resolved_at:=now();
 elsif new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at then
  raise exception 'resolution_only_via_resolve';
 end if;
 return new;
end $function$;

create or replace function public.refresh_financial_reconciliation(p_proposal_id uuid,p_component_type text)
returns uuid language plpgsql set search_path=public as $$
declare v_org uuid;v_channel uuid;v_expected numeric;v_reported numeric;v_settled numeric;v_case uuid;v_status text;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null then raise exception 'proposal_not_found'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
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
 perform set_config('corban.reconciliation_rpc','on',true);
 insert into public.financial_reconciliation_cases(organization_id,proposal_id,channel_id,component_type,expected_amount,reported_amount,settled_amount,status)
 values(v_org,p_proposal_id,v_channel,p_component_type,v_expected,v_reported,v_settled,v_status)
 on conflict(organization_id,proposal_id,(coalesce(component_type,'__none__'))) do update set expected_amount=excluded.expected_amount,reported_amount=excluded.reported_amount,settled_amount=excluded.settled_amount,
   status=case when public.financial_reconciliation_cases.status='resolved' then 'resolved' else excluded.status end,updated_at=now()
 returning id into v_case;
 perform set_config('corban.reconciliation_rpc','off',true);
 return v_case;
end $$;
