# Audit 2026-09-24 - pilot readiness (users, access lifecycle, worker readiness, product UX)

Branch `architecture/corban-os-master-v2`. Entry state: `20260923_worker_dispatch_hardening_v1` and `20260924_confirm_paid_replay_v1` LIVE (handoff 38fb59e). This wave applied nothing to the database; every SQL harness ran rollback-only.

## Findings
| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | No screen or RPC let an organization owner add, re-role, deactivate or audit team members; `organization_memberships` could only be changed by bootstrap SQL. | P0 | `20260925_team_access_lifecycle_v1` (NOT LIVE) + `/app/equipe` |
| 2 | The only invitation path (`/api/admin/organizations`) sent an e-mail whose link had no handler in the app (no `/auth/*` route, no password screen), so an invited person could not finish onboarding. | P0 | `/auth/definir-senha` (client, session from the link), `/auth/confirm` (token_hash, fixed destination) |
| 3 | `/access-pending` was a dead end (no sign-out, no re-check). | P1 | Verify-again, sign-out, invitation acceptance on load |
| 4 | Commission visibility was decided in 6 places with the literal `supervisor`. | P1 | Single `canViewCommission`; unit test pins every screen to it |
| 5 | Fake providers were shown as "Disponível (local)" next to real ones. | P1 | Explicit `LOCAL / TESTE - não é banco` label on cards and on runs |
| 6 | Dashboard mixed "não consultável" with zero and had no leads / integrations cards. | P1 | Honest `indisponível` state, leads, integrations needing attention, reconciliations pending; expected commission labelled as forecast |
| 7 | Agents can read `expected_commission_amount` columns through the API (per-row RLS). | P0 decision | NOT changed (needs Owner decision); documented in the gap analysis |

## Design of the team module (all SECURITY INVOKER; no new SECURITY DEFINER)
- `organization_invitations`: pending/accepted/revoked/expired, one pending per (organization, e-mail), 7-day expiry, no token column.
- `organization_admin_events`: append-only audit (invite created/revoked/accepted, role changed, deactivated, reactivated); a test proves no token/password/secret content.
- `organization_memberships`: authenticated keeps SELECT and UPDATE(role,status,updated_at) only; INSERT and DELETE revoked; guard trigger refuses any write outside the RPCs; identity columns are immutable even for service_role.
- Policy: admin manages everyone; manager only supervisor/agent (current and new role); nobody manages themselves; supervisor/agent nothing. Last-admin loss is structurally impossible (only admins touch admins, never oneself), proved by an invariant check.
- Acceptance is service_role-only and receives the identity from `supabase.auth.getUser()` after checking `email_confirmed_at`; an existing active member's role is never changed by an invitation; a revoked member is reactivated with the invited role (explicit outcome).
- Revocation is effective at the database: the next query of a deactivated user returns nothing and every RPC refuses (proved with reads and with `transition_operational_case`).
- Abuse limits: 20 invitations per actor per hour (database-enforced); e-mail sending rate is Supabase Auth's own limit.

## Evidence
| Suite | Result |
|---|---|
| `team-access-rollback.sql` (migration + adversarial: roles, tenants, forged ids, replay, expiry, revocation, audit, grants, triggers, DEFINER inventory) | 131/131 |
| `pilot-e2e-rollback.sql` (invite -> accept -> lead -> customer -> proposal -> esteira -> fake run claiming "paid" -> dashboard numbers -> mid-flow deactivation -> reactivation -> financial truth untouched) | 45/45 |
| `worker-dispatch-hardening-rollback.sql`, LIVE mode, no prelude (regression of the LIVE migration) | 24/24 |
| Unit (`npm run test:unit`) | 171/171 (new: 18 in `team-access.test.ts`) |
| `tsc --noEmit`, `eslint --max-warnings 0`, `next build` | clean |
| Live after all runs: leads/clients/proposals/cases/runs/artifacts/financial_events/reconciliation = 0; organizations 2, memberships 2, users 3 (pre-existing); invitations table absent (not applied) | zero residue |
| SECURITY DEFINER inventory | exactly the 8 reviewed functions |
| Security advisors | 0 WARN / 0 ERROR (2 intentional INFO on closed admin tables) |
| Secret scan (tracked files, client bundles, logs) | no secret; only synthetic test literals |

## State
LIVE: everything through 20260924. NOT LIVE (prepared, adversarially tested): `20260925_team_access_lifecycle_v1`. IMPLEMENTED in code and dormant until the migration is applied (pages show "pendente de migration" instead of failing): `/app/equipe`, acceptance on access-pending. EXTERNAL GATE: Auth Site URL / Redirect URLs, SMTP, worker secret, scheduler. DEFERRED: Bevicred. BLOCKED: 2Tech real file. PRODUCT DECISION: agent commission visibility.

## External dependencies for invitations
1. Supabase Auth -> URL Configuration: Site URL = production origin; Redirect URLs must include `<origin>/auth/definir-senha`.
2. Auth e-mail: a real SMTP sender (the default sender is heavily rate limited and not for production).
3. Optional, more robust: change the Invite/Recovery templates to `<origin>/auth/confirm?token_hash={{ .TokenHash }}&type=invite` (server-verified, no token in the URL fragment).
4. Enable password rules (minimum length >= 10 is enforced by our form; Auth policy should match) and Leaked Password Protection.
