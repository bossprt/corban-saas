# Audit 2026-09-19 — tenant resolution, live blockers, ledger write paths

Method: read live function/policy definitions, then exercised them as a synthetic `authenticated` user inside
transactions that always end with `RAISE EXCEPTION` (nothing persisted; verified afterwards: no new functions, no new rows).
Fixtures were synthetic; no financial or commercial data was persisted.

## 1. Implicit-tenant resolution (`organization_memberships ... limit 1`)

Classification: **A** = vulnerability / must fix now; **B** = architectural debt; **C** = safe because the resource is validated afterwards.

| Function (live) | Class | Reason |
|---|---|---|
| `attach_import_batch_adapter` (prepared) | A → fixed | Was resolving tenant by `limit 1`; now the **batch** decides the tenant, membership is checked in that tenant, same error for missing/foreign batch. |
| `publish_financial_reversal` (prepared) | A → fixed | Tenant now derived from the reversed event (RLS-scoped read) + role check in that tenant. |
| `refresh_financial_reconciliation` | A → fixed in prepared migration | Tenant now derived from the proposal. |
| `publish_expected_commission` | A-lite → fixed in prepared migration | Tenant derived from the proposal; also sets the guard token. |
| `apply_approved_import_match`, `create_and_publish_commission_rule`, `create_and_publish_split_rule`, `publish_financial_evidence_event`, `ingest_normalized_import_batch` | C (+B) | Org picked by `limit 1`, then every resource id is validated `and organization_id = v_org`; a multi-org user gets a fail-closed error (wrong org), never a cross-tenant write. Debt B: multi-org users are effectively unsupported. |
| `create_customer_with_timeline` | B | No resource id; creates in the *oldest* membership org (`order by created_at limit 1`), no role check. Needs an explicit `p_organization_id` validated against membership. |
| `transition_operational_case`, `generate_import_match_candidates` | safe pattern | Tenant derived from the case / batch. Use as the reference pattern. |
| App `requireAppContext()` | B | `.maybeSingle()` on active memberships: a user with 2+ active memberships fails closed to `/access-pending`. Multi-org selection is not implemented. |

Recommended B follow-up (not done automatically): one tenant-resolution helper that takes the resource id, or an explicit
`p_organization_id` validated against `organization_memberships` for RPCs without a resource.

## 2. Live blockers found (never exercised: the live DB had no real end-to-end user before)

1. **`has_active_organization_role` not executable by `authenticated`** (`rbac_helper_exposure_patch`). RLS policies and every
   SECURITY INVOKER RPC evaluate it as the caller → `42501 permission denied for function has_active_organization_role` for
   every role-gated write. Fix prepared: `20260919_restore_rbac_helper_execute_v1.sql`.
2. **`digest()` unqualified with `search_path=public`** in `ingest_normalized_import_batch` and `publish_financial_evidence_event`
   (pgcrypto lives in `extensions`) → `42883 function digest(text, unknown) does not exist`. Fix prepared: `20260919_fix_digest_search_path_v1.sql`.
3. **`financial_reconciliation_cases` directly writable** by supervisor+ (policy, no trigger): amounts/status could be forged.
   Fix prepared: `20260919_reconciliation_cases_write_hardening_v1.sql`.
4. **Ledger write paths**: `commission_expected`, `reversal`, `adjustment` and other event types could be inserted directly
   (only three evidence types were guarded); reconciliation **added** reversals instead of subtracting.
   Fix prepared: `20260919_financial_reversal_paths_v1.sql`.

## 3. Reversal model (corrected)

* Multiple **partial** reversals of one original are allowed; the earlier `UNIQUE(organization_id, reverses_event_id)` was removed.
* Cumulative reversed amount ≤ original; reversal of reversal/adjustment rejected; idempotency by
  `reversal:<event>:<sha256(amount|source|reference)>` (same request returns the same event).
* **Concurrency:** a transaction-scoped advisory lock keyed by the original event is taken in the RPC *and* in the guard trigger
  **before** the cumulative sum is read (READ COMMITTED re-reads committed rows per statement; other isolation levels are rejected).
  A plain `SELECT SUM` + `INSERT` would let two concurrent transactions each see the old total. A real concurrent test
  cannot run in a rollback-only harness (uncommitted rows are invisible across sessions); structural assertions verify the lock
  precedes the sum, and the trigger re-checks the invariant even if the RPC is bypassed.
* Adjustments stay **blocked** (no governed publisher). Other ungoverned event types (`network_share_expected`, `bonus_expected`,
  `downstream_payable`) are blocked as well.
* Reconciliation subtracts reversals from the bucket of the event they reverse, never goes negative, refreshes are serialized.

## 4. Remaining debt / accepted risks

* GUC tokens (`corban.financial_*_rpc`) are defence in depth, not a hard boundary against a caller with arbitrary SQL. A hard
  boundary = revoke INSERT on `financial_events` from `authenticated` and make publishers SECURITY DEFINER (B).
* Commission masking is application-level; RLS does not filter columns (B).
* `ingest_normalized_import_batch` dedupes by SHA-256 per tenant across sources; the app now rejects a reuse under a different source (B).
* Restoring EXECUTE on the RBAC helper may raise an advisor WARN; long-term fix is a non-exposed `private` schema for helpers (B).
