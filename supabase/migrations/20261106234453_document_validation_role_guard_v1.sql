-- Document checklist decisions only by Supervisor, Gerente or Administrador, also through the API (audit G2, 06/11/2026).
-- The update path already refused a validation, refusal or waiver by a seller (20260918_rbac_hardening_v0), but:
--   1. any member could INSERT a checklist item already 'validated' or 'waived' (the guard ran only on UPDATE);
--   2. any member could rewrite the reason / approver of a waiver after it was approved;
--   3. an authenticated caller without an active membership row got NULL as role, and "NULL not in (...)" let it pass.
-- Now: a new item always starts 'missing' with no waiver data (the checklist RPCs already insert it that way); the waiver
-- data changes only together with the waiver itself; an authenticated caller without a privileged role is refused.
-- Server-side callers without a user (service role, workers) keep the previous behaviour.
-- Contract: tests/security/document-validation-role-contract.sql

create or replace function public.guard_proposal_document_requirement_insert()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.status is distinct from 'missing'
     or new.exception_reason is not null
     or new.exception_approved_by is not null
     or new.exception_approved_at is not null then
    raise exception 'document_requirement_must_start_missing';
  end if;
  return new;
end;
$function$;

revoke all on function public.guard_proposal_document_requirement_insert() from public, anon, authenticated;

drop trigger if exists proposal_document_requirements_insert_guard on public.proposal_document_requirements;
create trigger proposal_document_requirements_insert_guard
before insert on public.proposal_document_requirements
for each row execute function public.guard_proposal_document_requirement_insert();

create or replace function public.guard_proposal_document_requirement_workflow()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_role text;
  v_privileged boolean;
begin
  select m.role into v_role
  from public.organization_memberships m
  where m.organization_id=new.organization_id and m.user_id=auth.uid() and m.status='active';
  -- No user (service role) keeps the previous behaviour; a user without an active privileged membership is refused.
  v_privileged := auth.uid() is null or coalesce(v_role, '') in ('admin','manager','supervisor');

  if new.status is distinct from old.status then
    if old.status='missing' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='attached' and new.status not in ('validated','rejected','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='rejected' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status in ('validated','waived') then
      raise exception 'terminal_document_requirement_status';
    end if;

    if new.status in ('validated','rejected','waived') and not v_privileged then
      raise exception 'document_decision_requires_privileged_role';
    end if;
  end if;

  -- Waiver data is written once, with the waiver.
  if (new.exception_reason is distinct from old.exception_reason
      or new.exception_approved_by is distinct from old.exception_approved_by
      or new.exception_approved_at is distinct from old.exception_approved_at)
     and not (new.status='waived' and old.status is distinct from 'waived') then
    raise exception 'document_exception_is_immutable';
  end if;

  if new.status='validated' and old.status is distinct from 'validated' then
    if not exists (
      select 1 from public.proposal_document_links l
      join public.customer_documents d
        on d.organization_id=l.organization_id and d.id=l.customer_document_id
      where l.organization_id=new.organization_id
        and l.requirement_id=new.id
        and d.document_type_id=new.document_type_id
        and d.status='active'
    ) then raise exception 'validated_requirement_requires_active_matching_document'; end if;
  end if;

  if new.status='waived' and old.status is distinct from 'waived' then
    if auth.uid() is null or new.exception_approved_by is distinct from auth.uid() then
      raise exception 'waiver_approver_must_be_current_user';
    end if;
    if not v_privileged then
      raise exception 'waiver_requires_privileged_role';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function public.guard_proposal_document_requirement_workflow() from public, anon, authenticated;
