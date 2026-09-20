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

- **SQL rollback-only harness** `tests/security/commercial-model-v3-rollback.sql`: 139 checks, run against the live project (migration text + harness in one transaction, ended by `RAISE EXCEPTION`): **`RESULTS: ALL PASS (139 checks)`**. Post-run check: 0 V3 tables, 0 residue organizations (nothing persisted).
- **Unit:** 263/263 (`tests/unit/commercial-v3.test.ts` adds 29).
- `npx tsc --noEmit` clean; `npx eslint src scripts tests --max-warnings 0` clean; `npm run build` OK (`/app/comercial` listed).

## 5. Adversarial review — findings and fixes

Found by running the harness, fixed in the migration/harness and re-run:
1. `guard_org_catalog_row` / `guard_condition_write` read `new.template_id` / `new.id` on tables without those fields (plpgsql does not short-circuit `and`): switched to `to_jsonb(new)->>…`.
2. **Real gap:** names were unique on `lower(name)`, so `'  BANCO x '` bypassed the duplicate check: unique indexes are now on `lower(btrim(name))` (banks, providers, agreements, groups, contract types).
3. Harness: the "superseded version" scenario never published v1 (test bug), and the unknown-template error text was the guard's own `national_template_not_available` (accepted alongside the FK error).

Other checks that passed: cross-tenant FKs and RPC attacks, agent/supervisor/inactive-manager denials, forged guard token on a published version, direct writes refused, agents read pricing but zero commission/shares, DEFINER inventory unchanged, no float columns, no financial events created.

Pre-existing drift fixed while running the suite: `tests/unit/worker-hardening.test.ts` expected importers of the admin client did not include `src/app/platform/actions.ts`, `src/app/platform/page.tsx`, `src/lib/appContext.ts` (already true at HEAD; those modules are server-side and guarded by platform-admin/context checks). The list now matches reality.

### 5b. Owner additions received while this wave was running (`docs/CORBAN-COMMERCIAL-MODEL-V3.md` §19–§23) and what was done

The doc grew by 604 lines (commits `019ac1a`…`58a23d1`) before the Human Gate. Because they change the schema, they were folded into the SAME unapplied migration instead of leaving a follow-up DDL:

| Doc section | Decision | Status |
|---|---|---|
| §19.2/§19.3 Origem da Produção | Route carries `production_origin` (`own` \| `third_party`); `third_party` requires the origin company (`org_provider_id`), `own` forbids it (CHECK, NULL-safe); provider types gain `correspondent` and `partner`; the tenant registers its own origin companies | Implemented + tested |
| §20.2–§20.4 Política de repasse | `payout_policies` / `payout_policy_versions` / `payout_policy_items`: tenant-owned rate card of % of the commission RECEIVED per group, IMMUTABLE versions (each save = new version), reused by any number of conditions, per-group override traceable (`source` = manual / policy / override) | Implemented + tested |
| §20.3 Bruta x líquida | Version carries `base_kind` gross \| net and `discount_pct`; the condition stores received (gross), `net_base_pct` and the policy version applied; effective % = `round(base x pct / 100, 6)` derived in the database | Implemented + tested |
| §20.5 Importação XLSX/CSV com prévia | Whole-file validation, "Validar (prévia, não grava)" then "Importar"; policy chosen on the import fills blank groups | Implemented (single-transaction bulk RPC still a follow-up) |
| §20.6 PDF, §21 agente de importação por IA, §22 IA medida, §23 agente operacional | Need an AI provider key, metering/credits and spend: Human Gate. Not implemented. The deterministic pipeline (parser + validators + preview + policy) built here is exactly the layer the agent is meant to sit on. | Deferred |
| §19.1 CEP com preenchimento automático | Customer-form UX, independent of this migration; needs an outbound lookup. Not implemented. | Deferred |

**Defect found by re-reading the doc against my own rule:** the first cut capped the SUM of production-basis shares by the commission received. The V3 example row (Corretor 4 + Parceiro 3,5 + Indicador 1 + Funcionário 2 + Supervisor 0,3 + Gerente 0,2 = 11% against 7% received) and the Owner policy (65% + 80% + 50% + 25%) show groups are ALTERNATIVE sellers, not simultaneous payees. Fixed: the cap is per group (`production_shares_exceed_received_commission` when ONE group exceeds the received commission; received-basis percentages are 0..100 each). Harness and unit tests pin the alternatives case (4% + 3% against 5% is valid). Stacking of supervisor/manager on top of a seller is a rule for the future payout engine, not for this table.

## 6. Known limits / follow-ups (not Human-Gate)

- The condition import validates the whole file first, then saves line by line through the governed RPC (idempotent: same Tipo de Contrato + prazo updates). A database refusal midway leaves the earlier lines saved; re-sending the file is safe. A single-transaction bulk RPC is a follow-up.
- Editing a draft condition drops the share of a group that was deactivated after the condition was saved (the form only offers active groups).
- The CEP autofill (§19.1) and the AI agents (§20.6, §21–§23) are documented by the Owner and intentionally not built here (see 5b).
- Commission groups are stored per condition but NOT yet wired into `proposal_commercial_snapshots` / `network_split_rule_versions` / repasse calculation. Received commission and repasse stay separate concepts; the repasse engine is a later wave.
- The Platform Admin screen for the national templates is not built (templates come from the migration; `/api/admin/reference-catalog` is legacy and can be deprecated once tenants migrate).
- Legacy global tables and `/app/catalogo` remain for existing rows; their retirement needs a data-migration decision.

## 7. Human Gate

Applying `20261002_commercial_model_v3_foundation_v1` LIVE is DDL on production (12 new tables — including the payout policy tables —, altered `organization_product_routes`, replaced `publish_product_table_version`). It needs explicit authorization. Evidence above (harness ALL PASS 139 checks, zero residue, unit/tsc/eslint/build green). After authorization: apply via the reviewed path, re-run the harness read-only, confirm advisors (RLS on every new table) and the DEFINER inventory.
