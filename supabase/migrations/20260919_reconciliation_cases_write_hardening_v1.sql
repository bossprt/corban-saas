-- PREPARED, NOT APPLIED (Human Gate: new production DDL). DEPENDS on 20260919_financial_reversal_paths_v1.sql
-- (its refresh_financial_reconciliation sets the token below).
-- Finding (adversarial review): financial_reconciliation_cases has an UPDATE policy for admin/manager/supervisor and
-- no trigger, so any supervisor could rewrite expected/reported/settled amounts or set status='matched' directly,
-- creating reconciled "truth" without evidence. Amounts and status are DERIVED from the append-only ledger and may
-- only be written by refresh_financial_reconciliation. Humans may still RESOLVE a case (status='resolved' with a
-- non-blank note); the resolver identity/time are stamped from the session, not client-supplied.
do $$
begin
 if pg_get_functiondef('public.refresh_financial_reconciliation(uuid,text)'::regprocedure) not like '%corban.reconciliation_rpc%' then
  raise exception 'apply 20260919_financial_reversal_paths_v1 first';
 end if;
end $$;

create or replace function public.guard_reconciliation_case_write()
returns trigger language plpgsql set search_path=public as $$
begin
 if current_setting('corban.reconciliation_rpc',true)='on' then return new; end if;
 if tg_op='INSERT' then raise exception 'reconciliation_case_requires_governed_rpc'; end if;
 if new.organization_id is distinct from old.organization_id or new.proposal_id is distinct from old.proposal_id
    or new.channel_id is distinct from old.channel_id or new.component_type is distinct from old.component_type
    or new.expected_amount is distinct from old.expected_amount or new.reported_amount is distinct from old.reported_amount
    or new.settled_amount is distinct from old.settled_amount then
  raise exception 'reconciliation_amounts_are_derived';
 end if;
 if new.status is distinct from old.status then
  if new.status<>'resolved' then raise exception 'reconciliation_status_is_derived'; end if;
  if nullif(btrim(new.resolution_note),'') is null then raise exception 'resolution_note_required'; end if;
  new.resolved_by:=auth.uid(); new.resolved_at:=now();
 end if;
 return new;
end $$;
revoke all on function public.guard_reconciliation_case_write() from public,anon,authenticated;
drop trigger if exists trg_reconciliation_case_write on public.financial_reconciliation_cases;
create trigger trg_reconciliation_case_write before insert or update on public.financial_reconciliation_cases
for each row execute function public.guard_reconciliation_case_write();
