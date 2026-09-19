# Audit 2026-09-19 (round 2) — rollback E2E against the live schema

Method: full flow executed with the LIVE functions as deployed, as synthetic `authenticated` users, inside a single
`DO` block that always ends with `RAISE EXCEPTION` (nothing persisted; verified afterwards). Fixtures were synthetic;
structural rows that need long FK chains were created under `session_replication_role='replica'` inside the same
rolled-back transaction. No real users, organizations or financial data were created.

Live state at the start: LIVE = revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1,
financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1. NOT LIVE = import_batch_adapter_lineage_v1 and everything below.

## Bugs found that block or corrupt real usage (all fixes are PREPARED, none applied)

| # | Severity | Finding | Fix (prepared migration) |
|---|---|---|---|
| 1 | A | `generate_import_match_candidates` used `min(uuid)` (not defined in PostgreSQL 17): every row with an external number/table code raised `42883`, so import matching never worked and the ingestion action always reported "matching falhou". | `fix_import_matching_uuid_aggregate_v1` (`(array_agg(x))[1]`) |
| 2 | A | `import_applied_decisions` has no INSERT policy: `apply_approved_import_match` (invoker) failed with RLS for every user, so no approved match could be applied and no financial fact published from an import. | `import_apply_rls_v1` |
| 3 | A | Matching compares institutions with `lower()`, apply compared case-sensitively and INSERTED a duplicate identity for the same proposal; afterwards the matcher counted 2 identities → `ambiguous` → `strong_match_required` forever for that proposal. | `import_identity_case_normalization_v1` (lower() lookup, stored lower-cased, unique index on `lower(institution_key)`) |
| 4 | A | Any active member (including `agent`) could INSERT `import_match_candidates` (forge an `exact` candidate) and `proposal_external_identities` (bind an external number to any tenant proposal). | candidates: guard trigger + token inside the matcher (`fix_import_matching…`); identities: supervisor+ policy (`import_apply_rls_v1`) |
| 5 | A | Every active member could SELECT financial events, evidence, reconciliation cases, commission rules and split rules through the API; hiding the React screen is not access control. | `financial_read_rbac_v1` (supervisor+). Not covered (needs column-level views, debt B): `proposal_commercial_snapshots`, `import_normalized_rows.commission_*`. |
| 6 | (earlier round) | RBAC helper not executable by authenticated; unqualified `digest()`; reconciliation cases writable; reversal model. | already LIVE |

## What the E2E proved (44 checks, `tests/security/e2e-financial-flow-rollback.sql`)

expected 100 → commission statement 120 (reported) → payment 100 (received) → reconciliation expected 100 / reported 120 /
settled 100 → reversal 20 (reported → 100) and chargeback 40 (settled → 60, case `divergent` again) → human resolution stamped by
the database, amounts intact. Also: replay/duplicate file, exact match case-insensitive, `commercial_offer` cannot prove money,
financial fact requires an applied identity match, agent read/publish denied, tenant B blocked on every RPC and read, the ledger
cannot be updated/deleted by members, no negative bucket.

Other harnesses: `tenant-ab-adversarial-rollback.sql` (19, customers/proposals/channels/rules/RPCs), `import-conflicts-rollback.sql`
(24), `rbac-helper-and-lineage-rollback.sql` (32), `financial-reversal-behavior-rollback.sql` (57),
`reconciliation-cases-hardening-rollback.sql` (10).

## Operational pipeline map (what exists vs. gaps)

Lead → Customer → Simulation → Proposal → Documents → Digitization → External submission/import → Matching → Operational status →
Commission → Payment → Reconciliation.

* Exists and reachable in the app: Customer (`create_customer_with_timeline`, `/app/clientes`), Simulation, Proposal
  (`create_proposal_from_simulation`), Documents (`prepare_proposal_documents`), Digitization (`send_proposal_to_digitization`),
  Operations (`transition_operational_case`), Import/2Tech, Matching, PAID by evidence (`confirm_proposal_paid_from_import`),
  Expected/Reported/Received, Reconciliation, Reversal, Resolution (new UI).
* Gaps: **Lead** has no entity (a customer is created directly); **external submission** is represented only by import evidence
  (no outbound integration; Bevicred deferred); no browser-driven E2E (no test identity/credentials — Human Gate).
* Invariant kept: operational status and financial facts are independent; approval/WON never creates commission received; PAID
  requires evidence.
