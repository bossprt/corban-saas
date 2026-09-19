# Pilot gap analysis (revalidated 2026-09-24, updated after closure wave 2)

Method: every P0 of the 2026-09-23 version was re-proved against the code, the LIVE database and the harnesses. Nothing here is guessed; each line names its evidence.

Classification: RESOLVED (code + tests, waiting only for a NOT LIVE migration to be applied), REAL P0, EXTERNAL GATE, PRODUCT DECISION, NOT P0, STALE.

## What works end to end (rollback-only harnesses on the live schema)
Invite -> accept -> lead -> customer -> simulation -> proposal -> documents -> esteira -> integration run (worker, lease, fencing, retry, cancel, re-execution) -> evidence -> import/matching -> financial truth only through governed evidence -> reconciliation. Tenant isolation, RBAC, revocation and the financial firewall (a provider saying "paid" / commission 999999 creates no financial fact) were attacked with every role. Pilot E2E: `tests/security/pilot-e2e-rollback.sql` (45 checks).

## P0 revalidation
| # | Gap (2026-09-23) | Now | Evidence |
|---|---|---|---|
| P0-1 | Apply worker_dispatch_hardening_v1 + confirm_paid_replay_v1 | STALE - both are LIVE (20260919140756, 20260919140800) | ChatGPT handoff 38fb59e; live advisors/inventory checked 2026-09-24 |
| P0-2 | Team management: invite, roles, revocation | RESOLVED and LIVE (`20260925_team_access_lifecycle_v1`, applied as 20260919160840); LIVE regression 83/83 | `team-access-rollback.sql` 131/131, `pilot-e2e-rollback.sql` 45/45, unit `team-access.test.ts`; page `/app/equipe` |
| P0-2b | Invited person could not set a password (no `/auth/*` handler existed, so the existing platform invite e-mail led nowhere) | RESOLVED in code | `/auth/definir-senha`, `/auth/confirm`; first-login acceptance in `/access-pending` |
| P0-3 | Someone must trigger the worker | EXTERNAL GATE (secret + scheduler are Owner decisions); runbook + readiness panel ready | `docs/integrations/WORKER-DEPLOYMENT.md`, readiness in `/app/integracoes` |
| P0-4 | Should an agent see expected commission? | PRODUCT DECISION. App side is centralised and fail-closed in `canViewCommission` (supervisor+). DB side unchanged: see "Commission visibility" below | `rbac.ts`, unit test pins every screen to the function |
| new | Auth e-mail configuration | EXTERNAL GATE: Site URL / Redirect URLs must allow `<origin>/auth/definir-senha`; SMTP sender; optional token-hash template | see "External dependencies" |

## Commission visibility (pending business decision)
Today: supervisor, manager and admin see commission/financial data in the app; agents do not (dashboard, financeiro, proposal financial events, import commission columns all call `canViewCommission`).
Known DB fact: `simulations.expected_commission_amount` and `proposals_v2.expected_commission_amount` are column values readable by any member of the tenant through the API (RLS is per row, not per column). The app does not display them to agents, but an agent calling the API directly could read them. Closing that needs a NEW migration (column privileges or a view) AFTER the Owner decides; it was not done here because it would change data access without that decision.
To change the policy: edit `canViewCommission` (one line) and, if agents must NOT read the column, add the migration above.

## Closure wave 2 (2026-09-24)
| # | Item | State |
|---|---|---|
| S-1 | Simulations were writable directly by any member with forged amounts, actor and expected commission (flowed into proposals) | RESOLVED in code + `20260926_simulation_governance_v1` (NOT LIVE, awaiting ChatGPT review). Action works before and after the migration (temporary fallback) |
| S-2 | Table metadata copied into simulation snapshots (may carry commercial terms) | RESOLVED (RPC no longer copies it) |
| R-1 | Forgot password | RESOLVED: `/login/recuperar`; needs the Auth configuration in `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md` |
| H-1 | Attempt history screen | RESOLVED: per-run history in `/app/integracoes` |
| A-1 | Operator "needs attention" panel | RESOLVED: deterministic, role-aware, on the dashboard |
| U-1 | Raw esteira states | RESOLVED: pt-BR labels + next step |
| PERF-1 | Advisor WARN `multiple_permissive_policies` on `organization_memberships` (introduced by the team migration) | RESOLVED in `20260927_membership_select_policy_merge_v1` (NOT LIVE); 12/12 identical-visibility checks |

## P1 - right after the pilot starts
- Simulation cancel/expire has no governed path yet (no UI needs it); `expected_commission_amount` on simulations has no governed source and stays NULL.
- First real provider (2Tech waits for a real file; Bevicred deferred).
- Operator notification when a run needs a human.
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
