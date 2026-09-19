# Audit 2026-09-20 — closure wave (column security, multi-org, resolution audit trail, leads, outbound)

Live state confirmed at the start (`supabase_migrations.schema_migrations`): revoke_excess_table_privileges_v1,
restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1,
fix_import_matching_uuid_aggregate_v1, import_apply_rls_v1, import_identity_case_normalization_v1, rbac_helper_security_invoker_v1,
financial_read_rbac_v1, import_batch_adapter_lineage_v1. NOT live: import_conflicts_v1 and every `20260920_*` file below.
Method: read-only catalog queries, then rollback-only harnesses (single DO block ending in RAISE EXCEPTION; nothing persisted).

## Block A — column security (`20260920_column_security_and_tenant_derivation_v1`)
`authenticated` is one DB role for all app roles, so column grants cannot separate agent from supervisor. Design: operational columns stay
selectable; economic columns are served only by `private` SECURITY DEFINER readers that enforce membership + supervisor+ (public entry points are
SECURITY INVOKER wrappers: `list_import_rows`, `get_commercial_route`). Restricted: `import_normalized_rows.{commission_upfront,commission_deferred,amount,normalized_payload}`,
`proposal_commercial_snapshots.{commission_rule_version_id,split_rule_version_id,snapshot}`. Functions that read them were re-written
(matching, apply, confirm-paid, publish-fact, publish-expected). App queries were migrated with fallbacks that behave correctly BEFORE and AFTER the migration.
**Bug found by this work:** the private readers used `role not in (...)`; a NULL role (non-member) makes that NULL, not true, so tenant B could call
`get_commercial_route` on tenant A's proposal. Fixed with `coalesce(role,'')` and a regression in the E2E harness (7 mini-checks + 60+ E2E).
Open (business decision, not changed): `proposals_v2.expected_commission_amount/commercial_snapshot`, `simulations.expected_commission_amount/result_snapshot`,
legacy `contracts.commission_percentage` are readable by agent; whether an agent may see the commission of their own simulation is a product decision.

## Block B/C — multi-organization and resource-derived tenant
Nine live functions resolved the tenant with `organization_memberships ... limit 1`. All now derive it from the resource (decision, source, proposal, channel,
relationship, row) and then require an ACTIVE membership/role there. `create_customer_with_timeline` takes an explicit `p_organization_id`; the legacy
5-argument form only works for a user with exactly one active membership and otherwise raises `organization_required`. Note for callers: PostgREST resolves by
named arguments; a positional call with untyped literals can hit the legacy overload, so use named arguments or cast the organization to uuid.
App: `requireAppContext` no longer uses `.maybeSingle()`; it reads all active memberships, resolves the tenant with `resolveActiveMembership` (one -> that one;
several -> explicit cookie, re-validated on every request; otherwise redirect to `/organizacao`) and returns a client scoped to the active organization
(`scopeToOrganization`: select/update/delete always filtered; catalog tables exempt). Coherent rule for `product_table_external_identities`: catalog
configuration = manager+ (RLS policy) and `apply_approved_import_match` now requires manager+ for the table-identity path.

## Block D — financial resolution audit trail (`20260920_reconciliation_resolution_immutability_v1`)
Live `guard_reconciliation_case_write` protected amounts/status but, with `status` unchanged, let supervisor+ rewrite `resolution_note`, `resolved_by`, `resolved_at`
(forge the audit trail, rewrite a justification, write a note on an open case). Also `refresh_financial_reconciliation` overwrote `status` of a resolved case, orphaning
the resolution columns. Fix: the resolution triple only changes with the open->resolved transition, is stamped from the session, immutable afterwards; refresh keeps a
resolved case resolved (amounts still update, the UI flags "recalculated after resolution"). Ledger append-only, reversals, ungoverned events and adjustments were already
proven live by the 44-check E2E (ALL PASS) and are unchanged. Harness: 17 checks.

## Block E — import conflicts (NOT LIVE)
Reviewed in the previous round (30/30). UI has three explicit states (store missing / query failure / available) and works before and after the migration.

## Block F — Lead (`20260920_leads_v1`, NOT LIVE)
Audit: no lead entity existed. Added a minimal CRM register + append-only timeline: provenance (channel/campaign/external ref), idempotent intake, writes only through
governed RPCs, write-once customer link, conversion atomic and idempotent, no financial columns. 29 rollback checks (tenant A/B, revoked, multi-org, atomicity).

## Block G — outbound integrations (code only)
`src/lib/integrations/executor.ts`: provider contract, run ledger interface (maps to integration_runs), idempotent by fingerprint, no double submission, bounded
retries with backoff, stale-RUNNING takeover, terminal errors, secret redaction, external providers blocked by default, **Bevicred refused always**. Local fake adapter
and in-memory repository; no network, no credentials, nothing real sent.

## Residual risks
GUC tokens are defence in depth, not a boundary against arbitrary SQL; `detail` of a conflict is caller-supplied; app-level scoping of multi-org reads relies on the
scoped client (RLS alone admits all of the user's organizations); commission visibility on `proposals_v2`/`simulations` is undecided; browser E2E needs a test identity.
