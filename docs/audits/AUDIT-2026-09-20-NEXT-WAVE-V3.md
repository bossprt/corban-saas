# Audit — Next wave V3 (UX + CEP, atomic import, AI import foundation, metering, Action Center, payout integration design)

**Date:** 2026-09-20 · **Branch:** `architecture/corban-os-master-v2` · **Plan:** `docs/NEXT-WAVE-PLAN-V3.md`
**Rule kept:** no `main`, no LIVE migration, no Gemini key, no external cost, no financial change. Everything below is prepared/tested on the branch.

## 1. What was done, by wave

| Wave | Delivered | DDL | Evidence |
|---|---|---|---|
| A1 `/app/comercial` | Guided "Passo a passo" (6 steps computed from real counts, one highlighted next step), anchors, empty-state guard for the table form | none | unit |
| A2 CEP | `/api/cep` (auth required, key-less ViaCEP, fixed host, 4 s timeout, 30/min/user), `AddressFields` (fills only empty untouched fields, saved values protected, number/complement manual, never blocks the save), address saved as the customer's PRIMARY row in the **existing** `customer_addresses` | **none** (see §2) | unit |
| B atomic import | `import_commercial_conditions` RPC (one transaction, every line through `save_commercial_condition`, all-or-nothing, per-line refusal list in `DETAIL`, idempotent by version + Tipo de Contrato + prazo, 500-row cap, version row lock); app uses it and keeps the old path only while the RPC does not exist | `20261004_commercial_bulk_import_v1` (prepared) | rollback-only harness: 22/23 on the first run; the one failure was a wrong expectation of the harness (an inactive member no longer sees the version), fixed |
| C AI import foundation | `src/lib/ai-import`: closed canonical fields, layout/file fingerprint, deterministic validator (invented/duplicate columns dropped; money fields need confidence ≥ 0.85 **and** numeric evidence in the sample; unknown columns preserved), memory reuse only for an identical layout, heuristic + scripted mappers, Gemini adapter with an **injected** key (no env access, no key, no call), orchestrator that reserves credits before calling and falls back to manual on every failure | memory table in `20261005_ai_import_metering_v1` | 21 unit tests |
| D metering | `organization_ai_limits` (AI **off** by default), `ai_usage_jobs`, append-only `ai_credit_ledger` + `ai_usage_events`, `reserve_ai_job` / `settle_ai_job` (idempotent, balance + monthly ceiling, no overrun), platform-only grants (service_role), provider cost stored apart from credits charged, no price anywhere | `20261005_ai_import_metering_v1` (prepared) | harness ALL PASS 62 |
| E Action Center | pure deterministic rules (`attention-rules.ts`, evidence, severity by age/volume, a rule whose data could not be read is not evaluated), `operational_attention_items/events` with lifecycle (open/snoozed/dismissed/resolved, dismissal needs a reason, resolved is final, append-only history), `/app/atencao` | `20261006_action_center_v1` (prepared) | harness ALL PASS 55 |
| F payout integration | design only (§3) | none | — |

## 2. Audit findings (including my own mistakes)

1. **Duplicate model avoided late:** I first prepared `client_addresses` for the CEP. Before applying anything I inspected LIVE and found `customer_addresses` (composite tenant FK to clients + member RLS) already there. The migration and harness were deleted; the app uses the existing table. Rule adopted: **inspect the LIVE table list before designing DDL**.
2. **plpgsql does not short-circuit `and`** (again): `guard_attention_write` read `new.rule_key` on a table without that column; fixed by nesting. Same class as `guard_org_catalog_row` in V3.
3. **Same-statement snapshot artifact** (again): a function's own writes are invisible to a `select` in the same statement; harness checks were split.
4. `FOR UPDATE` on `organization_ai_limits` needs an UPDATE privilege the tenant must not have: replaced by a per-tenant advisory lock.
5. Server-action safety: the CEP route never forwards the upstream body and only interpolates the validated 8 digits; the Gemini adapter turns every failure into one opaque code (no URL/key/body).
6. Prompt-injection surface: sample rows from an uploaded file go into the prompt. The model output is never trusted (validator), values never leave the sample, and nothing is imported without the human preview.
7. Known limits: primary-address update is read-then-write (two concurrent first saves could create two primary rows; low impact, a partial unique index would close it — optional DDL); the Action Center syncs on page load by a supervisor (a scheduled sync is a later wave); assignment RPC exists but has no UI yet (member display names are not exposed).

## 3. Wave F — payout / proposal snapshot / ledger: audit and minimal integration design (NO DDL, NO code on financial tables)

**LIVE facts (read-only inspection):** `proposals_v2` (has `commercial_snapshot`, `attribution_snapshot`, `expected_commission_amount`; frozen after draft by `guard_proposal_commercial_snapshot`), `proposal_commercial_snapshots` (`snapshot jsonb`, `commission_rule_version_id`, `split_rule_version_id`), `proposal_commercial_component_snapshots`, `commission_rule_components` (percentage/fixed/anticipation, `calculation_base`), `network_split_rule_versions` (`downstream_share`, `upstream_share`, `payment_flow`), `financial_events` (append-only, event types `commission_expected`, `network_share_expected`, `commission_reported`, `payment_received`, `downstream_payable`, `downstream_paid`, `reversal`, `adjustment`), `financial_reconciliation_cases` (expected/reported/settled/divergence). **All of them have 0 rows** — nothing historical can be affected yet.

**Two engines, one owner decision.** The existing engine models the *bank→company* leg through channel commission rule versions and the *company→network* leg through split rules. V3 models the *received commission per condition* and the *company→group* leg through payout policies. They overlap on "received". Proposed split (needs Owner confirmation, ADR-0025 pending):
- **Received leg (bank pays the company):** V3 condition `received_commission_pct` is the reference; a proposal snapshot freezes it (and the channel rule, when one exists) — expected/reported/received stay distinct ledger facts.
- **Payout leg (company pays the seller group):** V3 group `effective_pct` + policy version, frozen in the snapshot; the ledger records `downstream_payable` only from the frozen snapshot, `downstream_paid` only from payment evidence.

**Missing piece found:** V3 has commission groups but **no binding of users/teams to groups** (V3 doc §8 "a empresa vincula usuários/equipes aos grupos"). Without it a proposal cannot say which group's percentage applies. Required first step: `commission_group_members` (user ↔ group, tenant-scoped, effective-dated) and an attribution rule at proposal creation.

**Minimal integration, in order (each one a separate Human Gate):**
1. `commission_group_members` + attribution (which group produced the proposal). Additive.
2. Proposal snapshot of the V3 condition: store it in `proposal_commercial_snapshots.snapshot` under a `commercial_model_v3` key (condition id, Tipo de Contrato, prazo, coefficient, rate, received %, base used, policy version, the applied group and its effective %), written by the proposal RPC in the same transaction as the proposal. **Do not** put it in `proposals_v2.commercial_snapshot`: agents can read their proposals, so commission would leak. First check to run before the DDL: RLS of `proposal_commercial_snapshots` must be supervisor+.
3. Ledger: emit `commission_expected` (received leg) and `downstream_payable` (payout leg) with `source_kind='proposal_snapshot'`, `idempotency_key` = proposal + component, amounts NUMERIC from the snapshot. Base (requested vs released amount) is a business decision: the Owner must choose it before step 3.
4. Reconciliation keeps working unchanged (it compares expected/reported/settled).
5. A later policy change never touches a proposal: the snapshot is immutable (existing guard) and the ledger only moves by compensating events.

**Human decisions needed for wave F:** (a) which base the commission is calculated on (requested or released amount) and when; (b) confirm the two-leg split above; (c) how a user is attributed to a group (single group per user? per product?); (d) supervisor/manager stacking on top of the seller group.

## 4. Human Gates reached (none of them can be crossed without the Owner)

1. Apply, in order: `20261004_commercial_bulk_import_v1`, `20261005_ai_import_metering_v1`, `20261006_action_center_v1` (DDL LIVE; all additive, harnesses green).
2. Register the Gemini API key (secret) and wire `geminiMapper` in a server module.
3. Authorize the first paid call and set the credit rate card + monthly ceilings (platform side).
4. Any financial/payout DDL (wave F steps 1–3).


## Independent ChatGPT verification — 20/09/2026

After Claude's report, ChatGPT independently reran all three rollback-only migration harnesses against the LIVE schema without persisting DDL or test data.

Results:
- `20261004_commercial_bulk_import_v1`: initially reproduced 1 failing harness assertion. Root cause was a **same-statement snapshot visibility artifact in the test**, not a migration defect: the assertion called the mutating RPC and selected its newly written row inside the same SQL statement. The production behavior was debugged and confirmed correct (`ok`, 1 row created, tenant organization correct). The harness was fixed by splitting the call and read into separate statements, commit `b2d5253a9439326b2f1ed4e31390b1519ae5977a`. Re-run: **ALL PASS (22 checks)**.
- `20261005_ai_import_metering_v1`: independent rollback-only re-run: **ALL PASS (62 checks)**.
- `20261006_action_center_v1`: independent rollback-only re-run: **ALL PASS (54 checks)**.

The final exception in each harness is the intentional rollback sentinel. No migration was applied LIVE and no synthetic test data persisted.

Human Gate remains unchanged: explicit Owner authorization is still required before applying 20261004, 20261005 and 20261006 LIVE.


## 5. LIVE apply — 20/09/2026

Owner explicitly authorized the three pending DDL gates. ChatGPT applied the migrations LIVE in the required order:

- `20260920173825 commercial_bulk_import_v1`
- `20260920173830 ai_import_metering_v1`
- `20260920173835 action_center_v1`

**Do not reapply.**

Post-apply validation against LIVE:
- Commercial bulk import harness: **ALL PASS (22 checks)**.
- AI import + metering harness: **ALL PASS (62 checks)**.
- Action Center harness: **ALL PASS (54 checks)**.
- The final exception in each harness is the intentional rollback sentinel; no synthetic test data persisted.
- All seven new persisted AI/Action Center tables checked have RLS enabled.
- Application SECURITY DEFINER inventory remains unchanged at 8 functions (6 private + 2 public); these migrations introduced no new SECURITY DEFINER functions.
- Security Advisor: no WARN/ERROR; only the same two intentional INFO entries for closed platform-admin tables.
- Performance Advisor: INFO only. Current unindexed-FK inventory is 19, including new AI/Action Center FKs and prior V3 findings; no performance WARN/ERROR.
- Immediately after apply: import mapping, AI limits/jobs/credit ledger/events, attention items/events all contain zero rows.

Note on evidence count: the current Action Center harness contains **54** assertions. Earlier execution notes said 55; the verified LIVE run is 54/54 and the repository harness is the authority.

Human Gates still pending:
1. Gemini API secret registration / server wiring.
2. First paid Gemini call.
3. Credit tariff and tenant monthly limits.
4. Any payout/financial DDL from Wave F.
