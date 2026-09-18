# Audit 2026-09-19 — SECURITY DEFINER inventory and RBAC helper

Live state at audit time (read-only catalog queries + one read-only HTTP probe with the public anon key).
Classes: **A** dangerous exposure / fix now · **B** acceptable for now, debt · **C** necessary and correctly hardened.

PostgREST exposes only `public` and `graphql_public` (probe: `Invalid schema: private` / `extensions`). The advisor WARN
("SECURITY DEFINER executable by authenticated") applies to functions in exposed schemas.

## Inventory (application schemas)

| Function | Schema | anon | authenticated | search_path | Tenant source | Class | Notes |
|---|---|---|---|---|---|---|---|
| `has_active_organization_role(uuid,text[])` | public | no | **yes** | `''` | caller's own memberships via `auth.uid()` | **A → fixed (prepared)** | Definer was unnecessary: `organization_memberships` has a single policy `select_self` that does not call the helper (no recursion) and exposes exactly the rows the helper reads. Now SECURITY INVOKER; same signature; 36 policies (21 tables) + 10 functions unchanged. No user argument, so a client cannot ask about someone else. |
| `bootstrap_organization_admin(...)` | public | no | no | `''` | platform admin actor validated in `platform_administrators` | C (+B) | EXECUTE only `postgres`/`service_role` (server side). Creates org + admin membership + audit. Debt B: the actor id is a parameter, so the server caller must pass a verified actor; `p_plan_type` is not validated in the function. |
| `get_user_organization_id()` | public | no | no | `''` | `profiles.organization_id limit 1` | B | Legacy helper, service_role only (auth.uid() is null there). Candidate for removal once nothing references it. |
| `pgbouncer.get_auth` | pgbouncer | no | no | `''` | n/a | C | Platform managed. |
| `private.attach_import_batch_adapter` (prepared) | private (not exposed) | no | yes (needs USAGE) | `''` | **the batch** | C | Only writer of adapter lineage; see design below. Public entry point `public.attach_import_batch_adapter` is SECURITY INVOKER. |

No SECURITY DEFINER triggers exist. No definer function builds dynamic SQL (`EXECUTE`): no injection surface found. None can
alter financial truth: the financial publishers are SECURITY INVOKER and rely on RLS + guard triggers.

Checks performed per function: schema exposure, EXECUTE for PUBLIC/anon/authenticated, `search_path`, `auth.uid()` use,
tenant derivation (resource vs client), dynamic SQL, escalation path (does it write roles/memberships/financial rows),
enumeration (do errors differ between foreign and missing resources).

## `has_active_organization_role` — decision

Options considered:
1. Move to a `private` schema and keep a public wrapper → still needs a definer in private; unnecessary complexity.
2. Rewrite 36 policies + 10 functions to `private.` → large, regression-prone, no benefit.
3. **Make it SECURITY INVOKER (chosen).** Same result for every input because RLS on memberships already restricts the read to
   the caller's own active rows. Verified in a rollback-only harness (32 checks): admin/agent/revoked/no-membership/unknown
   tenant, RLS policies on `commercial_entities` still admit an admin and deny agent and cross-tenant inserts.

## Adapter lineage — design (`import_batch_adapter_lineage_v1`, replaces the blocked draft)

* Batch is the tenant authority; membership must be active **in the batch's organization**; caller is the batch receiver or
  admin/manager/supervisor; no `limit 1`, no organization argument.
* Adapter must exist (not disabled) and equal the batch's real `parser_key`; lineage is write-once (trigger, independent of the RPC);
  only the governed step may set it (transaction-local token).
* Foreign batch, missing batch, unauthorized member, revoked member, anonymous → identical error `batch_not_found_or_forbidden`.
* Why a definer exists at all: `import_batches` has no UPDATE policy for `authenticated`. Column-level UPDATE grants would break
  `generate_import_match_candidates` (UPDATEs `status` as invoker); an UPDATE policy would allow editing any column. The write is
  therefore done by one narrow definer in the non-exposed `private` schema, EXECUTE only for `authenticated`, `search_path=''`, fully
  qualified names, updating only `adapter_id`/`adapter_contract_version` while `adapter_id is null`.
* Harness: `tests/security/rbac-helper-and-lineage-rollback.sql`; inventory guard: `tests/security/security-definer-inventory-contract.sql`.

## Residual debt (B)

* `bootstrap_organization_admin` actor parameter and unvalidated plan type; `get_user_organization_id` removal.
* `generate_import_match_candidates` runs `update import_batches ... status` as invoker; with no UPDATE policy it is a silent no-op.
  Behaviour is harmless today but the statement is dead; decide whether batch status should be governed.
* Advisor re-check needed after the migrations are applied: expected result is the WARN disappearing.
