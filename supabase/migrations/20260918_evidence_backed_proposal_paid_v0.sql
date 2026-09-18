-- CORBAN OS V2 — Evidence-backed proposal paid state V0
create table if not exists public.proposal_status_evidence(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 proposal_id uuid not null references public.proposals_v2(id),
 import_decision_id uuid not null references public.import_decisions(id),
 canonical_status text not null check(canonical_status in ('paid')),
 raw_status text not null,
 evidenced_at timestamptz not null,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,import_decision_id,canonical_status)
);
alter table public.proposal_status_evidence enable row level security;
revoke all on public.proposal_status_evidence from anon;
grant select,insert on public.proposal_status_evidence to authenticated;
create policy proposal_status_evidence_select on public.proposal_status_evidence for select to authenticated using(public.is_active_organization_member(organization_id));
create policy proposal_status_evidence_insert on public.proposal_status_evidence for insert to authenticated with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']) and created_by=(select auth.uid()));
create index if not exists proposal_status_evidence_proposal_idx on public.proposal_status_evidence(proposal_id);
create index if not exists proposal_status_evidence_decision_idx on public.proposal_status_evidence(import_decision_id);

create or replace function public.guard_proposal_status_transition() returns trigger language plpgsql set search_path='' as $$
begin
 if new.status is not distinct from old.status then return new; end if;
 if old.status='draft' and new.status not in ('documents_pending','ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='documents_pending' and new.status not in ('ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='ready_for_digitization' and new.status not in ('documents_pending','digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='digitization' and new.status not in ('submitted','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='submitted' and new.status not in ('approved','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='approved' and new.status not in ('paid','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status in ('paid','rejected','cancelled') then raise exception 'terminal_proposal_status'; end if;
 if new.status='paid' and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on' then raise exception 'paid_requires_confirmed_operational_evidence'; end if;
 return new;
end $$;

create or replace function public.confirm_proposal_paid_from_import(p_decision_id uuid)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_org uuid;v_batch uuid;v_candidate uuid;v_proposal uuid;v_payload jsonb;v_semantic text;v_raw_status text;v_at timestamptz;v_id uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;
 select c.proposal_id,n.normalized_payload into v_proposal,v_payload from public.import_match_candidates c join public.import_normalized_rows n on n.id=c.normalized_row_id and n.organization_id=c.organization_id where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null and n.record_kind='status';
 if v_proposal is null then raise exception 'exact_status_proposal_match_required'; end if;
 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 if v_semantic<>'production_report' then raise exception 'production_report_required'; end if;
 if lower(coalesce(v_payload->>'canonicalStatus',''))<>'paid' then raise exception 'paid_status_evidence_required'; end if;
 v_raw_status:=nullif(v_payload->>'rawStatus','');v_at:=nullif(v_payload->>'occurredAt','')::timestamptz;
 if v_raw_status is null or v_at is null then raise exception 'status_evidence_details_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=v_proposal and organization_id=v_org and status='approved') then raise exception 'proposal_must_be_approved'; end if;
 insert into public.proposal_status_evidence(organization_id,proposal_id,import_decision_id,canonical_status,raw_status,evidenced_at,created_by)
 values(v_org,v_proposal,p_decision_id,'paid',v_raw_status,v_at,auth.uid()) on conflict(organization_id,import_decision_id,canonical_status) do update set raw_status=excluded.raw_status returning id into v_id;
 perform set_config('corban.paid_evidence_rpc','on',true);
 update public.proposals_v2 set status='paid',updated_at=now() where id=v_proposal and organization_id=v_org;
 perform set_config('corban.paid_evidence_rpc','off',true);
 return v_id;
end $$;
revoke all on function public.confirm_proposal_paid_from_import(uuid) from public,anon;
grant execute on function public.confirm_proposal_paid_from_import(uuid) to authenticated;