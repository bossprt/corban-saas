# Audit 2026-09-25 - deployment and tenant preparation (wave 4)

Branch `architecture/corban-os-master-v2`. Entry: HEAD ac144dc (`revoked_actor_dispatch_v1` LIVE). Nothing was applied, created or configured externally by this wave; every SQL harness ran rollback-only.

## Answer to the wave question
"Does only the Owner's external configuration and real Smart data remain?" - **Yes, plus one review**: `20260929_catalog_publish_v1` must be reviewed and applied by ChatGPT (a database change, not an Owner action). Everything else independent is done.

## Findings
| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | Global reference tables (banks, providers, agreements, products, modalities, document_types) are empty and tenant roles are read-only: a tenant admin can never create a route, hence never a table or a checklist. Only SQL could seed them. | P0 | Platform-admin route `GET/POST /api/admin/reference-catalog`: strict validation, idempotent upsert by code, never deletes, audited in `platform_admin_audit_events`; template file with placeholders only |
| 2 | Tenant admin could create table versions and checklists but not publish them: UPDATE policies require `status='draft'` in USING and WITH CHECK, and no publish RPC exists. Also INSERT policies did not constrain `status` (a manager could insert an already-published version). | P0 | `20260929_catalog_publish_v1` (NOT LIVE): publish RPCs (INVOKER), draft-only inserts, guard trigger, supersede on publish; 40/40 |
| 3 | Catalog page was a read-only counter; nothing to configure checklists or stages | P0 | `/app/catalogo`: routes, tables, versions, checklists, default stages; `/app/configuracao`: deterministic setup status. Every write is authorized by RLS/guards/RPCs; role checks only fail early |
| 4 | Organization bootstrap accepted any document text (uniqueness by exact string) and similar names | P1 | valid CNPJ (digits-only storage), duplicate document 409, similar-name 409 with explicit `confirmSimilarName`, tenant id from the database, existing compensation and audit kept |
| 5 | Upload limit 15 MB, but Vercel functions reject bodies above 4.5 MB (and Next's default server action limit is 1 MB) | P1 | limit 4 MB, `serverActions.bodySizeLimit` 5mb, message says so; P1 = signed direct-to-Storage upload |
| 6 | Supabase clients used `!` on missing env (cryptic failures); invitation origin trusted the request Origin header | P1 | `publicSupabaseEnv()` fails closed with a secret-free message; origin fallback only when host matches; explicit `NEXT_PUBLIC_SITE_URL` first |
| 7 | No local way to verify the environment | P1 | `npm run preflight`: PASS/WARN/BLOCKED, presence only, exits 1 on BLOCKED; worker absence is WARN |
| 8 | `authenticated` has INSERT/UPDATE/DELETE grants on `organizations` (no policies, RLS refuses) | P2 | recorded; revoke later |

## Deployability
- `next build` passes; env inventory complete (7 variables, `docs/deployment/ENVIRONMENT-VARIABLES.md`; a test checks that every variable read by the code is documented); service role only in server-only modules (architecture test); no `vercel.json` needed; Node 20/22.
- `/api/health`: minimal, cached 5 s, no configuration. Auth callback, recovery, invitation, access-pending, organization picker, logout audited in earlier waves and re-read here; no change needed.
- Not verified: an actual deployment (no hosting access), real e-mail delivery (no SMTP), real browser behaviour.

## Evidence
| Suite | Result |
|---|---|
| Unit | 229/229 (new: 37 in `deployment-wave4.test.ts`, plus updated architecture tests) |
| `tsc`, `eslint --max-warnings 0`, `next build` | clean |
| `catalog-publish-rollback.sql` (migration text + DO) | 40/40 (first run 38/40: two harness checks read a row inside the same statement that changed it; split, rerun clean) |
| `npm run preflight` locally | works; BLOCKED only because this workstation's `.env.local` has no service role key (expected) |
| Live: reference 0, tenant catalog 0, business rows 0, organizations 2 (tests), platform admins 1 | zero synthetic residue |
| SECURITY DEFINER | 8, anon EXECUTE 0 |
| Security advisor | 0 WARN / 0 ERROR (2 intentional INFO) |
| Performance advisor | not re-fetched this wave (no schema change was applied) |
| Migration drift | `docs/deployment/MIGRATION-DRIFT.md`: none beyond the NOT LIVE catalog migration and the pre-repo baseline |

## Not done / limits
- No browser E2E and no visual QA. The human acceptance test is written for that (`docs/pilot/SMART-HUMAN-ACCEPTANCE-TEST.md`).
- Regression suites of earlier waves (leads, operational, integration runs, worker, financial, conflicts, reconciliation, team, paid evidence) were not re-run: no LIVE object they use changed.
- No wizard was built: the existing flows plus the catalog page and setup status remove the need for SQL.
