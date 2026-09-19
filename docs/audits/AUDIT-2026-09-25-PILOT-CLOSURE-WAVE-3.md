# Audit 2026-09-25 - pilot closure wave 3 (1 real operator)

Branch `architecture/corban-os-master-v2`. Entry: `20260925`, `20260926`, `20260927` LIVE (HEAD 8a15fa3). Nothing was applied to the database by this wave; every SQL harness ran rollback-only.

## 1. Revoked-actor dispatch starvation - CONFIRMED and fixed (NOT LIVE)
- Evidence on the LIVE schema (harness `revoked-actor-dispatch-rollback.sql`, `fixed=false`): 12 runs created by a supervisor who is then deactivated, 1 valid run by an active manager. With the worker's pass size (10) the list returns 10 orphans and NOT the valid run; `claim` refuses the orphan actor (`actor_not_authorized`), the worker logs an error and moves on, and the same orphans are listed again on every pass. 6/6 checks passed = the bug is present.
- Fix `20260928_revoked_actor_dispatch_v1` (forward-only, INVOKER, no DEFINER): (1) the dispatch list returns only runs whose creator is still an active admin/manager/supervisor (the exact rule `claim` enforces); (2) `sweep_orphaned_integration_runs` (service_role only) ends orphans in a governed state: queued/retry-pending -> `cancelled`, expired-lease running -> terminally `failed`, fixed sanitized code and message; a manager can still create a linked re-execution. Creating new runs as a revoked user or an agent stays refused.
- Worker: `runDispatchCycle` calls `repo.sweepOrphans` first (best effort: a database without the function, or a failure, never stops dispatch); `swept` is reported as a count.
- Harness with the fix: 22/22. Unit: 3 new tests (order sweep -> list, failure tolerance, RPC arguments, migration shape).
- Also documented: artifacts are only writable for RUNNING runs, so orphan explanations live on the run row, not as diagnostics.

## 2. Operator experience findings and fixes
| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | Server actions threw `Error`; in production Next.js hides the message, so the operator would see only a generic failure with no explanation of what to correct | P0 | Actions redirect with a whitelisted code (`?f=ok:...`/`erro:...`); `FlashBanner` in the shell renders the fixed Portuguese text; the code is removed from the address bar. Applied to leads, clientes, simulações, documentos and the proposal document/send actions. Financial supervisor-only actions still throw (boundary shows a sanitized text) |
| 2 | Error boundary printed `error.message` | P0 | shows a neutral message and the reference digest only |
| 3 | Upload trusted the browser-declared MIME type | P0/P1 | real type decided from the first bytes (PDF/JPEG/PNG/WebP); declared and real must agree; empty and >4 MB refused (Vercel body limit); HTML/SVG/executable renamed to .pdf refused; stored name sanitized; stored `mime_type` is the real one |
| 4 | No search in Leads/Clientes | P1 | name/phone search (filter-language characters stripped; CPF is never a search key nor placed in a URL) |
| 5 | Lead list hid the phone and the linked customer | P1 | phone and "Ver cliente" shown |
| 6 | Simulation table dropdown showed a table UUID prefix; unknown installment could look like a value | P1 | table names; "Não calculado" for unknown; guidance when no customers/tables |
| 7 | Proposal/operation showed raw statuses | P1 | pt-BR labels + next step; `paid` labelled as evidence-backed; no screen offers "mark as paid" |
| 8 | Menu offered Catálogo, Rede, Importações, Configuração to everyone | P1 | role-aware menu; pages, actions and RPCs still enforce |
| 9 | Agent dashboard showed organization-wide numbers | P1 | agent sees "Meus leads" and "Minhas propostas" (created_by); supervision roles see the organization |
| 10 | Double submit had no feedback | P1 | `SubmitButton` (disables while pending) on the main forms; the database stays the real guard (idempotent lead conversion; one proposal per simulation, proved) |
| 11 | Lead CPF only checked for 11 digits | P1 | check-digit validation on conversion and customer creation |
| 12 | Login/first access | audited | root -> login; no membership -> access-pending (verify again / sign out, accepts a pending invitation); several memberships -> organization picker; inactive membership -> same neutral screen; used invitation does not re-admit (proved). No redirect loop found in code paths |

## 3. Session revocation, organization switch, PII
- Revocation: `requireAppContext` reads ACTIVE memberships on every request and RPC/RLS re-check; proved by the E2E (deactivated agent refused on lead, simulation, proposal, operation, integration and team; reads nothing).
- Organization switch: the chosen organization is a cookie re-validated against memberships on each request and every tenant table read is scoped to it; cross-tenant attacks over the whole chain proved closed.
- PII: CPF is masked on screen, never in a URL, search, feedback code or log line (tests pin the actions); document names are sanitized; attempt-history text is sanitized.

## 4. Not done / limits
- No browser automation: Playwright is not installed and no environment with credentials exists here. UI evidence = build, unit tests, source review. The checklist requires a human walkthrough.
- No visual QA (no screenshot tooling in this session); mobile relies on the existing responsive layout (stacked sidebar, horizontally scrollable tables, `min-w-0` main).
- Pagination: lists are capped at 100 (leads, clientes, propostas, casos); "next page" was not added because the pilot volume is far below the cap.
- Commission: unchanged and fail-closed; the Owner decision is still pending.
- Not re-run this wave: leads 47, operational E2E 72, integration runs 111, worker governance 125, financial E2E 93, conflicts 30, reconciliation 18, paid evidence 15, team 83 (no LIVE object they exercise changed in this wave; the pending migration only replaces the dispatch list and adds the sweep).

## 5. Evidence
| Suite | Result |
|---|---|
| Unit | 211/211 |
| tsc / eslint --max-warnings 0 / next build | clean |
| `revoked-actor-dispatch-rollback.sql` unfixed LIVE schema | 6/6 (bug confirmed) |
| same with the migration text | 22/22 |
| Pilot chain E2E against LIVE (no prelude; invite -> lead -> idempotent conversion -> governed simulation -> double-submit proposal -> esteira -> retry/history/re-execution -> paid firewall -> cross-tenant -> revoked user) | 35/35 |
| Live after all runs: leads/clients/simulations/proposals/cases/runs/artifacts/financial events/reconciliation/invitations/admin events | all 0 (zero residue) |
| SECURITY DEFINER | 8, anon EXECUTE on them 0 |
| Security advisors | 0 WARN / 0 ERROR (2 intentional INFO) |
| Performance advisors | the wave-2 `multiple_permissive_policies` warning has its cause removed (verified by policy count: 1 SELECT policy on organization_memberships; the advisor listing itself was not re-fetched in this wave); the rest is INFO (unused indexes on an empty database, not touched) |
| Smart Promotora organization | NOT FOUND (only 2 test organizations; 1 active platform administrator exists) |
