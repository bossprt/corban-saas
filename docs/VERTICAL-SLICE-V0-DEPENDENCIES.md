# VERTICAL SLICE V0 — DEPENDENCY MATRIX

| Migration | Depends on | Creates/changes | Gate |
|---|---|---|---|
| legacy RLS → membership | membership V2 | policies legadas | A/B auth |
| Customer 360 | organizations, clients, membership | customer children + soft delete | A/B auth |
| Product Catalog | organizations, membership | catalog/routes/tables/versions | A/B auth |
| Simulation/Proposal | Customer + Catalog | simulations/proposals_v2 | prior migrations |
| Document Vault | Customer + Route + Proposal | documents/checklists/requirements | prior migrations |
| Digitization/Pipeline | Proposal | jobs/cases/stages/events | prior migrations |

## Contracts
- `tests/security/customer-360-schema-contract.sql`
- `tests/security/product-catalog-schema-contract.sql`
- `tests/security/simulation-proposal-schema-contract.sql`
- `tests/security/document-vault-schema-contract.sql`
- `tests/security/digitization-pipeline-schema-contract.sql`

A ausência de contrato pós-DDL específico para a troca das policies legadas é coberta pelo harness A/B; antes da aplicação final deve existir também uma inspeção SQL de policies/grants.
