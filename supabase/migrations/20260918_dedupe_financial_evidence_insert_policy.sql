-- Mirror of live migration 20260918205240 dedupe_financial_evidence_insert_policy (already applied).
-- Repository reconciliation only; do not re-apply as new history.
drop policy if exists financial_evidence_links_insert_supervisor on public.financial_evidence_links;
