# Audit — Commercial Model V3 (impact, migration plan, implementation, adversarial review)

**Date:** 2026-09-26 · **Branch:** `architecture/corban-os-master-v2` · **Source of truth:** `docs/CORBAN-COMMERCIAL-MODEL-V3.md`
**Status:** implemented and tested on the branch. Migration `20261002_commercial_model_v3_foundation_v1` is PREPARED, NOT APPLIED (Human Gate below).

## 1. Impact audit (what the old model did and why it conflicts)

| Area | LIVE / legacy shape | Conflict with V3 |
|---|---|---|
| `banks`, `providers`, `agreements`, `products`, `modalities` | Global tables written by the platform (`/api/admin/reference-catalog`) | The tenant must own its operation; the platform must not register each company's banks/agreements |
| `agreements.bank_id` | A convênio belongs to one bank | National agreements (governments, city halls) must not be born bound to a bank |
| `modalities.product_id` | Tipo de Contrato hangs under a Produto | Tipo de Contrato must be independent of Produto |
| `organization_product_routes` | bank + provider + agreement + product + modality, all NOT NULL | Route must be bank + agreement (+ optional provider); product = the commercial table itself |
| `product_table_versions` | Scalar `rate`/`coefficient`/`term_min`/`term_max` per version | One version needs many (Tipo de Contrato, prazo) rows, each with coefficient/rate, received commission and group shares |
| Commission engine (`commercial_channels`, `channel_commission_rule_versions`, `commission_rule_components`, `network_split_rule_versions`, `proposal_commercial_snapshots`) | Prepared, not integrated with the catalog | Groups are not wired into it yet (follow-up, see §6) |
| UI `/app/catalogo` | Global dropdowns; tenant cannot create banks/agreements | Replaced as the primary entry by `/app/comercial`; legacy page kept for existing data |
| Simulations | `create_simulation` uses the version's scalar coefficient | Needs a condition-driven path |
| Imports (`src/lib/imports`) | Bank statement/commission imports | Unrelated to condition import; a new dedicated CSV/XLSX condition import was added |

Nothing was renamed, dropped or rewritten. No history is touched.

## 2. Migration design (`20261002_commercial_model_v3_foundation_v1.sql`)

Additive, forward-only, no SECURITY DEFINER, no rename/drop.

1. **Platform structure (global, read-only for tenants):** `contract_types` (4 seeds, no product/bank/tenant column), `national_agreement_templates` (27 governments incl. Distrito Federal + 26 capital city halls; no bank, no tenant; nothing enabled for anyone by default).
2. **Tenant-owned catalog:** `organization_banks`, `organization_providers`, `organization_agreements` (custom or enabled from a template, official name forced by the database), `commission_groups` (dynamic; `calculation_basis` enum). Opaque database-generated `tech_key`; names unique per tenant on `lower(btrim(name))`. Insert/update manager+, select member (groups: supervisor+). Nothing can be deleted.
3. **Routes:** `organization_product_routes` gains `org_bank_id/org_provider_id/org_agreement_id`; legacy columns become nullable; `CHECK organization_product_routes_shape` allows exactly one of the two shapes; composite tenant FKs; unique V3 key.
4. **Commercial conditions** (per draft version): `commercial_conditions` (pricing, readable by every member), `commercial_condition_commissions` and `commercial_condition_shares` (supervisor+). Only `save_commercial_condition` (INVOKER, guard-token GUC) writes them, all groups in ONE call; published versions are frozen by the guard itself. `publish_product_table_version` accepts a version priced only by conditions.
5. **`create_simulation_for_condition`:** coefficient/rate from the condition, tenant from the customer, no commission copied.
6. NUMERIC only (`numeric(14,8)` coefficient, `numeric(9,6)` rates/percentages).

## 3. Implementation

- `src/lib/commercial.ts` (pure): decimal-string parsing (never float), BigInt-scaled comparison, share validation mirroring the RPC (each basis on its own), CSV reader, condition import mapper with one column per commission group (unknown/duplicate/ambiguous columns refused, blank = not part of the condition).
- `src/lib/commercial-xlsx.ts`: XLSX reader that keeps duplicate headers apart.
- `/app/comercial` (page + actions): banks, providers, agreement enablement (national list) + own agreements, commission groups, tables (route and code generated), draft versions, single condition form with one input per active group, CSV/XLSX import, publish. Manager+ writes; supervisor+ reads; commission and shares only for `canViewCommission`.
- `/app/simulacoes`: optional Tipo de Contrato → `create_simulation_for_condition`; amount as decimal string.
- `/app/configuracao`: setup counts V3 banks/agreements and commission groups; legacy reference still counts.
- `TENANT_FREE_TABLES` + `contract_types`, `national_agreement_templates`; feedback whitelist + V3 codes.
- Users never type or see a technical code (no code field, no `tech_key` rendered; a unit test pins it).

## 4. Tests and evidence

- **SQL rollback-only harness** `tests/security/commercial-model-v3-rollback.sql`: 100 checks, run against the live project (migration text + harness in one transaction, ended by `RAISE EXCEPTION`): **`RESULTS: ALL PASS (100 checks)`**. Post-run check: 0 V3 tables, 0 residue organizations (nothing persisted).
- **Unit:** 257/257 (`tests/unit/commercial-v3.test.ts` adds 23).
- `npx tsc --noEmit` clean; `npx eslint src scripts tests --max-warnings 0` clean; `npm run build` OK (`/app/comercial` listed).

## 5. Adversarial review — findings and fixes

Found by running the harness, fixed in the migration/harness and re-run:
1. `guard_org_catalog_row` / `guard_condition_write` read `new.template_id` / `new.id` on tables without those fields (plpgsql does not short-circuit `and`): switched to `to_jsonb(new)->>…`.
2. **Real gap:** names were unique on `lower(name)`, so `'  BANCO x '` bypassed the duplicate check: unique indexes are now on `lower(btrim(name))` (banks, providers, agreements, groups, contract types).
3. Harness: the "superseded version" scenario never published v1 (test bug), and the unknown-template error text was the guard's own `national_template_not_available` (accepted alongside the FK error).

Other checks that passed: cross-tenant FKs and RPC attacks, agent/supervisor/inactive-manager denials, forged guard token on a published version, direct writes refused, agents read pricing but zero commission/shares, DEFINER inventory unchanged, no float columns, no financial events created.

Pre-existing drift fixed while running the suite: `tests/unit/worker-hardening.test.ts` expected importers of the admin client did not include `src/app/platform/actions.ts`, `src/app/platform/page.tsx`, `src/lib/appContext.ts` (already true at HEAD; those modules are server-side and guarded by platform-admin/context checks). The list now matches reality.

## 6. Known limits / follow-ups (not Human-Gate)

- The condition import validates the whole file first, then saves line by line through the governed RPC (idempotent: same Tipo de Contrato + prazo updates). A database refusal midway leaves the earlier lines saved; re-sending the file is safe. A single-transaction bulk RPC is a follow-up.
- Editing a draft condition drops the share of a group that was deactivated after the condition was saved (the form only offers active groups).
- Commission groups are stored per condition but NOT yet wired into `proposal_commercial_snapshots` / `network_split_rule_versions` / repasse calculation. Received commission and repasse stay separate concepts; the repasse engine is a later wave.
- The Platform Admin screen for the national templates is not built (templates come from the migration; `/api/admin/reference-catalog` is legacy and can be deprecated once tenants migrate).
- Legacy global tables and `/app/catalogo` remain for existing rows; their retirement needs a data-migration decision.

## 7. Human Gate

Applying `20261002_commercial_model_v3_foundation_v1` LIVE is DDL on production (new tables, altered `organization_product_routes`, replaced `publish_product_table_version`). It needs explicit authorization. Evidence above (harness ALL PASS, zero residue, unit/tsc/eslint/build green). After authorization: apply via the reviewed path, re-run the harness read-only, confirm advisors (RLS on every new table) and the DEFINER inventory.
