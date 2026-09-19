# Audit 2026-09-21 — operational integration wave

Live state at the start (confirmed by the ChatGPT application log, not re-applied): import_conflicts_v1, column_security_and_tenant_derivation_v1,
reconciliation_resolution_immutability_v1, leads_v1, leads_customer_fk_index_v1 are LIVE. Security Advisor after them: 0 WARN / 0 ERROR.
Live `integration_runs` had 0 rows and only SELECT for `authenticated`; writes were reserved to `service_role`, but nothing enforced a state machine.

## What was built (all local; nothing applied to Supabase)
| Block | Result |
|---|---|
| A repository | `SupabaseRunRepository` (service-role worker, RPC-only) + `InMemoryRunRepository` twin with identical semantics. Contract `RunRepository` = claim / complete / fail / cancel; ownership lives in the database. |
| B concurrency | `claim_integration_run` serializes on `SELECT … FOR UPDATE` over the unique identity (tenant, binding, fingerprint); a lease + fencing `claim_token` protects against zombie workers; expired leases are taken over (counts an attempt, bounded by `max_attempts`); a late commit with an untouched token is accepted so the provider is not called twice. |
| C state machine | Trigger `guard_integration_run_state`: queued→running, running→running (takeover)/succeeded/failed, failed→running only if non-terminal and attempts remain, queued/failed→cancelled. Success requires a `response_metadata` artifact. Identity (tenant, binding, adapter, capability, fingerprint, max_attempts) immutable. DELETE impossible. Artifacts are append-only. |
| D fake adapter | `ScriptedProvider` (success, delayed, duplicate, timeout, transient, permanent, malformed ×5, throws, leaky) with the same `ProviderAdapter` contract real providers will use. |
| E contract | `CapabilityManifest` per provider; the executor refuses undeclared capabilities; no provider-name branching. API and file providers coexist (`FAKE_MANIFEST` vs `FAKE_FILE_MANIFEST`, `TWOTECH_MANIFEST`). |
| F first real provider | 2Tech/BuscaContrato remains the closest candidate but is **blocked** (`awaiting_real_file`): registry entry, manifest, schema-fingerprint list still empty, unknown schema quarantined. Nothing invented. Bevicred DEFERRED. |
| G/H operational E2E | `tests/security/operational-e2e-rollback.sql`: Lead → Customer → Simulation → Proposal → Esteira → Integration Run → (provider says “paid”) → Financial Truth guard → Reconciliation, attacked as agent, supervisor, manager, admin, tenant B, revoked, no membership, multi-org and anon. |
| I UI | `/app/integracoes` with loading / permission denied / unavailable (pre-migration) / error / empty / data, and human phases (processing, retry scheduled, waiting for human action, completed, cancelled). |
| J observability | `RunLogger` with a WHITELIST event shape (correlation id, run id, provider, adapter, capability, attempt, duration, outcome, sanitized error). |

## Vulnerabilities / gaps found
1. **Esteira integrity (real, live).** `operational_cases`, `operational_events`, `digitization_jobs` accept INSERT/UPDATE from any active member through plain RLS policies; `authenticated` also holds UPDATE/DELETE grants on `operational_events`. An agent could forge esteira history or set a case to `canonical_state='paid'` through PostgREST. Not ledger truth, but it is what operators read. Fix prepared (NOT LIVE): `20260921_operational_pipeline_write_hardening_v1` (guard token set only by `send_proposal_to_digitization`, append-only events, excess grants revoked).
2. **Integration ledger had no state machine (live).** `service_role` could UPDATE a run from anything to anything, overwrite a succeeded run or delete evidence. Fixed in `20260921_integration_run_state_machine_v1` (NOT LIVE).
3. **Raw provider payloads readable by every member (live policy).** Runs/artifacts SELECT was `is_active_organization_member`; narrowed to supervisor+ in the same migration.
4. **Secret-like content could be persisted in run metadata/artifacts/error text.** DB guard rejects it; the app redacts first (idempotent redactor, tested).
5. Design bug caught by the harness while writing: the “secret” regex treated `"token": "[redacted]"` as a secret because `\s*` backtracked before the negative lookahead. Fixed (`(?!\s|…)`), covered by tests.
6. Design decision made from a harness result: fencing is by token, not by lease expiry, otherwise a slow-but-alone worker would lose a real provider result and force a second submission.

## Residual risks
- Migration text is not applied: until then the executor has no Supabase-backed state machine (the app UI degrades to the base columns).
- `service_role` is fully trusted (it bypasses RLS by design); its safety rests on the guard token + trigger, which are defence in depth, not a boundary against arbitrary SQL.
- `p_now` in the worker functions is caller-supplied (deterministic tests, single clock per worker); only `service_role` can call them.
- Membership revocation blocks new claims/retries/cancels but an in-flight completion is still recorded (the external effect already happened and must not be lost).
- `proposals_v2` UPDATE by any member remains policy-open (status guarded by trigger; commission visibility of own simulations is still an undecided business rule).
- `customer_timeline_events` INSERT is open to any member (write path still used by `create_customer_with_timeline`); UPDATE/DELETE are now revoked.
