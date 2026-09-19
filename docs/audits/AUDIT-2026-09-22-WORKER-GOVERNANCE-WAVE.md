# Audit 2026-09-22 — worker, dispatch, governed retry/cancel and security closure

Live at the start (ChatGPT, HEAD d2324b7): integration_run_state_machine_v1 and operational_pipeline_write_hardening_v1 are LIVE. Nothing was applied by this wave.

## Delivered (code, local)
Worker core + server wiring, bounded dispatch cycle, provider resolution guard (production / flag / registry / manifest identity), dispatch route (Bearer, disabled without secret), governed UI actions (retry = same run, cancel, re-execution with lineage and reason), metrics derivation, redaction at the persistence boundary.

## Findings
1. **LIVE regression (high).** The LIVE esteira hardening put guard-token triggers on `operational_cases`, `operational_events` and `digitization_jobs`, but `public.transition_operational_case` (the RPC behind /app/operacao) was not redefined to set the token. Every transition now fails with `operational_write_requires_governed_rpc`. My earlier review searched the app for direct writes and missed writes performed by other RPCs; lesson recorded: enumerate writers with a catalog scan of function bodies (done this time for proposals_v2 and customer_timeline_events). Fix: redefined in `20260922_worker_governance_v1`.
2. **proposals_v2 open to direct UPDATE/INSERT by any member.** Only the status machine and the snapshot guard protected it: an agent could rewrite `expected_commission_amount`, `customer_snapshot`, `attribution_snapshot`, amounts and terms, or insert a proposal as `approved`. The app never writes this table directly (only RPCs do), so all writes now require the governed token; identity columns are immutable even with the token; DELETE revoked. Trigger named to fire before older guards.
3. **customer_timeline_events accepted INSERT from any member (forged history).** Now append-only for everyone (including owner) and inserts require the token. `lead_write` (definer) keeps working through the owner path.
4. **Request payload reached storage unredacted in the in-memory twin.** Redaction now happens inside both repositories at the persistence boundary; the database guard remains the second lock.
5. Design consequence recorded: persisted requests are redacted, so dispatch executes references, not PII.

## Adversarial coverage
SQL (`worker-governance-rollback.sql`): every role (agent, supervisor, manager, admin, tenant B, revoked, no membership, anon, service_role) against proposals, timeline, esteira, enqueue, dispatch selection, lease/fencing/takeover, re-execution lineage, cancel; provider "paid" moves no proposal, writes no ledger event, resolves no reconciliation. Unit (`worker.test.ts`, 21): production guard, registry-only providers, two workers, timeout/transient/permanent/malformed/throw, revoked actor mid-flow, tenants, bounded cycles, redaction shapes incl. the `"[redacted]"` regression, trigger authorization, action matrix.

## Residual risks
- Until the migration is applied the esteira transition RPC stays broken live (see finding 1).
- The stored request is what runs: request authors must keep PII out of it.
- `service_role` is fully trusted; guards are defence in depth.
- No scheduler exists; nothing runs on its own.
