# Pilot gap analysis (revalidated 2026-09-24)

Method: every P0 of the 2026-09-23 version was re-proved against the code, the LIVE database and the harnesses. Nothing here is guessed; each line names its evidence.

Classification: RESOLVED (code + tests, waiting only for a NOT LIVE migration to be applied), REAL P0, EXTERNAL GATE, PRODUCT DECISION, NOT P0, STALE.

## What works end to end (rollback-only harnesses on the live schema)
Invite -> accept -> lead -> customer -> simulation -> proposal -> documents -> esteira -> integration run (worker, lease, fencing, retry, cancel, re-execution) -> evidence -> import/matching -> financial truth only through governed evidence -> reconciliation. Tenant isolation, RBAC, revocation and the financial firewall (a provider saying "paid" / commission 999999 creates no financial fact) were attacked with every role. Pilot E2E: `tests/security/pilot-e2e-rollback.sql` (45 checks).

## P0 revalidation
| # | Gap (2026-09-23) | Now | Evidence |
|---|---|---|---|
| P0-1 | Apply worker_dispatch_hardening_v1 + confirm_paid_replay_v1 | STALE - both are LIVE (20260919140756, 20260919140800) | ChatGPT handoff 38fb59e; live advisors/inventory checked 2026-09-24 |
| P0-2 | Team management: invite, roles, revocation | RESOLVED in code; needs `20260925_team_access_lifecycle_v1` applied (NOT LIVE) | `team-access-rollback.sql` 131/131, `pilot-e2e-rollback.sql` 45/45, unit `team-access.test.ts`; page `/app/equipe` |
| P0-2b | Invited person could not set a password (no `/auth/*` handler existed, so the existing platform invite e-mail led nowhere) | RESOLVED in code | `/auth/definir-senha`, `/auth/confirm`; first-login acceptance in `/access-pending` |
| P0-3 | Someone must trigger the worker | EXTERNAL GATE (secret + scheduler are Owner decisions); runbook + readiness panel ready | `docs/integrations/WORKER-DEPLOYMENT.md`, readiness in `/app/integracoes` |
| P0-4 | Should an agent see expected commission? | PRODUCT DECISION. App side is centralised and fail-closed in `canViewCommission` (supervisor+). DB side unchanged: see "Commission visibility" below | `rbac.ts`, unit test pins every screen to the function |
| new | Auth e-mail configuration | EXTERNAL GATE: Site URL / Redirect URLs must allow `<origin>/auth/definir-senha`; SMTP sender; optional token-hash template | see "External dependencies" |

## Commission visibility (pending business decision)
Today: supervisor, manager and admin see commission/financial data in the app; agents do not (dashboard, financeiro, proposal financial events, import commission columns all call `canViewCommission`).
Known DB fact: `simulations.expected_commission_amount` and `proposals_v2.expected_commission_amount` are column values readable by any member of the tenant through the API (RLS is per row, not per column). The app does not display them to agents, but an agent calling the API directly could read them. Closing that needs a NEW migration (column privileges or a view) AFTER the Owner decides; it was not done here because it would change data access without that decision.
To change the policy: edit `canViewCommission` (one line) and, if agents must NOT read the column, add the migration above.

## P1 - right after the pilot starts
- Simulations are written by direct INSERT/UPDATE from any member; same governed-RPC treatment already applied to proposals.
- First real provider (2Tech waits for a real file; Bevicred deferred).
- Attempt-history screen per execution (diagnostics exist in the database since worker_dispatch_hardening_v1).
- Operator notification when a run needs a human.
- "Forgot password" screen (recovery already lands on `/auth/definir-senha`; the trigger button on the login page is missing).
- Leaked Password Protection (Auth setting).
- Invitation e-mail for an address that already has an account (it sees the access after login; no e-mail is sent).
- Row-level `platform_administrators` UI (bootstrap of a NEW organization stays a platform action, see below).

## P2
Persisted worker metrics; cancellation of in-flight runs; execution priority; unused-index cleanup once real traffic exists; bulk member import.

## Platform bootstrap vs organization administration
- Platform bootstrap (creating an organization and its first admin): `POST /api/admin/organizations`, platform administrators only. Not self-service and not needed for the pilot: the pilot organization already exists.
- Organization administration (invite, role, deactivate, audit): `/app/equipe`, admin and manager (manager limited to supervisor/agent). Governed by RPCs, guard triggers and an append-only audit table.

## Implemented in this wave because it is independent and reversible
Team page, invitation acceptance, password setup, access-pending recovery paths (verify again, sign out), role-aware menu, pilot dashboard with honest "indisponível" states, LOCAL / TESTE labelling of fake providers, worker readiness panel, `/api/health`.
