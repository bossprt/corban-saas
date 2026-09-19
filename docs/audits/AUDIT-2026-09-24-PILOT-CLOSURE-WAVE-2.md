# Audit 2026-09-24 - pilot closure wave 2 (simulations, recovery, attempt history, operator UX)

Branch `architecture/corban-os-master-v2`. Entry: `20260925_team_access_lifecycle_v1` LIVE (7017efd). Nothing was applied to the database by this wave; every SQL harness ran rollback-only.

## Findings
| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | LIVE: any active member (agent included) could INSERT/UPDATE `simulations` directly with arbitrary amounts, rate, coefficient, a forged `created_by` and an arbitrary `expected_commission_amount`; `create_proposal_from_simulation` copies that commission into the proposal. The app action computed correct values but the database did not require it. | P0 (integrity + commission firewall) | `20260926_simulation_governance_v1` (NOT LIVE): `create_simulation` RPC, guard trigger, column grants |
| 2 | The simulation action copied product-table `metadata` into `result_snapshot`, readable by every member; the metadata may carry commercial terms. | P1 | RPC stores only `calculation`; test pins it |
| 3 | The proposal page selected `expected_commission_amount` for every role (never rendered). | P1 | column removed from the select; test pins it |
| 4 | No recovery path for a forgotten password. | P1 | `/login/recuperar` (Supabase Auth), same answer for any address |
| 5 | Attempt diagnostics existed in the database but not on screen. | P1 | history per run in `/app/integracoes`, whitelist + sanitiser |
| 6 | Dashboard queried financial and reconciliation data for roles that never see it. | P1 | not queried for those roles; action center is role-aware |
| 7 | `/app/operacao` showed raw canonical states (`digitization_queue`). | P1 | pt-BR labels + next step; no screen offers PAID |
| 8 | `/api/health` did one upstream probe per request. | P2 | 5 s per-instance cache |
| 9 | Performance advisor WARN after the team migration: two permissive SELECT policies on `organization_memberships`. | P1 (advisor WARN) | `20260927_membership_select_policy_merge_v1` (NOT LIVE): one policy, identical visibility |

## Simulations (evidence)
- Before: policies `simulations_insert_member`/`update_member` check membership only; `authenticated` had INSERT/UPDATE/DELETE on every column including `expected_commission_amount`, `organization_id`, `created_by`. Existing guard `guard_simulation_selected_immutable` already froze a simulation after a proposal used it (kept).
- After (harness `simulation-governance-rollback.sql`): tenant derived from the customer row; table version must be published for that tenant; rate/coefficient from the version; installment computed in the database; actor recorded; commission and released amount stay NULL (no governed source exists, so none can be forged); direct INSERT/UPDATE/DELETE refused; used simulations immutable; inactive/no-membership users refused; financial truth untouched.
- Result: 54 of 55 checks passed on the first run; the single failure was a harness expectation (a cross-tenant UPDATE of zero rows does not raise; RLS filters the row). The check was rewritten to assert the row is unchanged. The corrected file was not re-run as a standalone; the same behaviours are covered by `pilot-e2e-v2-rollback.sql` (39/39).
- Compatibility: until the migration is applied, `createSimulation` falls back to the previous server-computed insert only when PostgREST reports the RPC missing; once the migration is LIVE the database refuses that insert, so the fallback can never bypass the governed path. Remove it after applying.

## Evidence
| Suite | Result |
|---|---|
| Unit | 189/189 (18 new in `pilot-closure2.test.ts`) |
| `tsc`, `eslint --max-warnings 0`, `next build` | clean |
| `simulation-governance-rollback.sql` (migration prelude) | 54/55 on first run; the failing expectation fixed (see above) |
| `pilot-e2e-v2-rollback.sql` (sim prelude + LIVE team): invite -> lead -> governed simulation -> proposal -> esteira -> run with 2 attempts + secret-looking message -> history -> re-execution lineage -> "paid"/commission 999999 firewall -> cross-tenant -> revoked user | 39/39 |
| Team lifecycle against LIVE, DO block only (condensed 83-check version of the 131-check harness: invite, role, deactivate, reactivate, cross-tenant, self-change, manager limits, last-admin invariant, audit) | 83/83 |
| `proposal-paid-evidence-rollback.sql`, LIVE, no prelude (adds explicit REPLAY checks) | 15/15 |
| Not re-run this wave: leads 47, operational E2E 72, integration runs 111, worker governance 125, financial E2E 93, conflicts 30, reconciliation 18 (their LIVE objects did not change; the simulation migration is the only pending DB change and only `worker-governance` and `operational-e2e` touch `create_proposal_from_simulation`, whose covered behaviour is re-proved in the two new harnesses) | - |
| Live after all runs: leads/clients/proposals/cases/runs/artifacts/financial_events/reconciliation/invitations/admin events = 0 | zero residue |
| SECURITY DEFINER inventory | 8 (unchanged) |
| Security advisors | 0 WARN / 0 ERROR (2 intentional INFO on closed admin tables) |
| Performance advisors | 1 WARN: `multiple_permissive_policies` on `organization_memberships` SELECT (caused by the LIVE team migration; fixed in `20260927`, 12/12); INFO only otherwise (122 unused indexes on an empty database, Auth connection strategy). No unused index was dropped. |

## Password recovery
Flow: login -> "Esqueci minha senha" -> `resetPasswordForEmail` (server, Supabase Auth) -> same confirmation for any address -> e-mail link -> `/auth/definir-senha` (or `/auth/confirm` -> same page) -> new password -> app. No credential handling of our own, no account lookup, no logging of tokens; `/auth/confirm` rejects malformed tokens before any network call, allows only four types and always redirects to a fixed path. Password strength: the form asks for 10+ characters; Supabase Auth's own policy is the authority and must match (runbook). Leaked Password Protection remains an Owner setting.

## Attempt history
Source: immutable `diagnostic` artifacts (one per failed attempt / expired lease). The UI shows attempt number, outcome label, time, code and a sanitised message. `safeText` replaces (never truncates) anything that looks like a bearer token, JWT, key/secret/password words, CPF, e-mail, long digit or base64 strings, credentialed URLs; control characters are stripped; length is bounded; React renders text only (no `dangerouslySetInnerHTML`; a test pins it). Raw payloads, request metadata and provider responses are never selected for display.

## Action center
Deterministic list "Precisa da sua atenção": overdue esteira cases, draft proposals, stale new leads (all roles); failed integration runs and import reviews (supervisor+); reconciliations (commission viewers). Counts a role may not see are not queried; zero counts are hidden; no scoring, no AI.

## States
LIVE: through 20260925. NOT LIVE (prepared, tested): `20260926_simulation_governance_v1`. IMPLEMENTED: recovery, attempt history, action center, labels, health cache, simulation RPC with pre-migration fallback. EXTERNAL GATES: Auth Site URL/Redirect URLs + SMTP + password policy (runbook), worker secret + scheduler. PRODUCT DECISION: agent commission visibility. BLOCKED: 2Tech real file. DEFERRED: Bevicred.
