-- APPLIED LIVE by the independent ChatGPT audit on 2026-09-19 (authenticated/anon TRUNCATE, REFERENCES, TRIGGER = 0 tables). DO NOT RE-APPLY. Kept as repository history.
-- PREPARED, NOT APPLIED (Human Gate: remote privilege change; non-destructive and reversible with GRANT).
-- Adversarial review found that `authenticated` holds TRUNCATE/REFERENCES/TRIGGER on nearly every tenant table,
-- including financial_events, financial_evidence_links, import_raw_rows and organization_memberships.
-- TRUNCATE ignores RLS and row-level triggers (immutability/append-only guards do not fire), and REFERENCES
-- lets a role probe/attach foreign keys. None of these are needed by PostgREST clients or by the app.
-- SELECT/INSERT/UPDATE/DELETE stay governed by RLS and guard triggers and are intentionally unchanged.
do $$
declare t record;
begin
 for t in select tablename from pg_tables where schemaname='public' loop
  execute format('revoke truncate, references, trigger on table public.%I from anon, authenticated',t.tablename);
 end loop;
end $$;

-- Future tables created by the migration role must not re-acquire these privileges.
alter default privileges in schema public revoke truncate, references, trigger on tables from anon, authenticated;
