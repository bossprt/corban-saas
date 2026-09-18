-- Contract for Financial Truth Ledger V0.
do $$
begin
 if to_regclass('public.financial_events') is null then raise exception 'financial_events_missing'; end if;
 if to_regclass('public.financial_evidence_links') is null then raise exception 'financial_evidence_links_missing'; end if;
 if to_regclass('public.financial_reconciliation_cases') is null then raise exception 'financial_reconciliation_cases_missing'; end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name like 'financial_%' and grantee='anon') then raise exception 'anon_financial_access'; end if;
 if exists(select 1 from pg_policies where schemaname='public' and tablename in ('financial_events','financial_evidence_links') and cmd in ('UPDATE','DELETE')) then raise exception 'financial_history_mutable'; end if;
 if not exists(select 1 from pg_constraint where conrelid='public.financial_events'::regclass and contype='u' and pg_get_constraintdef(oid) ilike '%organization_id%idempotency_key%') then raise exception 'idempotency_constraint_missing'; end if;
end $$;
