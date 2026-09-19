# Audit 2026-09-23 — live regression, worker proof, scheduler readiness

Branch: `architecture/corban-os-master-v2`. No migration was applied by this wave. All SQL harnesses ran rollback-only (each ends in `RAISE EXCEPTION`), so no synthetic data remains.

## Live regression (state after `worker_governance_v1`, 20260919044054)
| Suite | Result |
|---|---|
| worker governance | 125/125 |
| integration runs | 111/111 |
| operational E2E | 72/72 |
| financial E2E | 93/93 |
| leads | 47/47 |
| unit (node test) | 153/153 |
| tsc, eslint (0 warnings) | clean |

Not rerun: import conflicts (30) and reconciliation (18); nothing they touch changed.
Advisors: security 0 WARN / 0 ERROR. SECURITY DEFINER inventory: the 8 reviewed functions, no new one.

## Findings and fixes (all in NOT LIVE migrations or application code)
1. Dispatch starvation: runs of adapters the worker cannot execute occupied every slot of a pass. Fix: `list_dispatchable_integration_runs(p_limit, p_now, p_adapter_keys)` filters in SQL; the worker passes only adapters it can run. Code falls back to the legacy 2-argument call if the migration is not yet applied.
2. Attempt history lost on retry: live error columns were cleared. Fix: one immutable `diagnostic` artifact per failed attempt and per expired lease.
3. A failure message that looked like a secret raised inside `fail_integration_run` and left the run in `running`. Fix: fixed markers are stored instead.
4. Replay of `confirm_proposal_paid_from_import` raised `proposal_must_be_approved`. Fix: idempotent replay returns the existing evidence.
5. Operational UI showed raw errors. Fix: classified messages.

## New migrations (NOT LIVE)
- `20260923_worker_dispatch_hardening_v1` — harness `worker-dispatch-hardening-rollback.sql`; last run against the live schema with the prelude: 40/40.
- `20260924_confirm_paid_replay_v1` — harness `proposal-paid-evidence-rollback.sql`: 18/18.

## States
LIVE: everything through worker_governance_v1. IMPLEMENTED (code): scoped dispatch, time budget, lineage UI, classified errors. NOT LIVE: the two migrations above. BLOCKED: 2Tech (no real file). DEFERRED: Bevicred. HUMAN GATE: applying the migrations, worker secret and scheduler, agent commission visibility, user invitation flow.
