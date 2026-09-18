# Reconciliation Engine V0

## Goal
Turn external evidence into deterministic links without silently changing catalog, proposal or financial truth.

## Identity priority
1. Existing external proposal identity: institution + proposal number.
2. Existing table alias: channel + external table code.
3. Producer identity: normalized CPF/CNPJ as supporting network evidence.
4. Amount/date/customer fields are corroborating evidence, never sole financial identity.

## Outcomes
- exact: one canonical proposal identity.
- strong: one canonical table/channel alias.
- probable: supporting evidence exists but a strong identity is missing.
- ambiguous: more than one candidate or conflicting strong evidence.
- none: no deterministic candidate.

Only exact/strong candidates may be offered for direct approval. Ambiguous/none are human-required.

## Separation of duties
Review decisions are append-only evidence. They do not mutate proposals, published tables, commission rules or ledger entries. A later application command must consume an approved decision transactionally and preserve the decision ID in lineage.

## Financial invariant
A report may prove production, entitlement, payment or status. Those are distinct facts. A matching proposal number does not by itself prove that a commission was received.
