# Import Adapter Contract V0

Adapters convert external commercial files into the Corban OS import staging model. They never publish catalog or financial truth directly.

## Common envelope

Every adapter emits:
- source: stable source key (for example `daycoval`, `efetiva_mais`, `bevicred`)
- original filename and SHA-256
- parser key/version
- one immutable raw payload per source row
- normalized record with explicit nulls for unknown fields

## Canonical normalized fields

`record_kind`, `bank_key`, `external_proposal_number`, `producer_tax_id`, `external_table_code`, `external_table_name`, `operation_type`, `term`, `rate`, `commission_upfront`, `commission_deferred`, `amount`, plus source-specific data in `normalized_payload`.

## Matching rules

1. Proposal: external proposal number is the strongest identity. Corban stores it defensively with institution/source scope; it never creates a second proposal when the canonical identity is already established.
2. Table: source code/name is an alias candidate. It must map to one canonical ProductTable; source naming never creates a duplicate automatically.
3. Producer: CNPJ identifies the producing network entity where supplied.
4. Channel: source/partner relationship identifies the commercial route independently from the bank/table.
5. Ambiguous/conflicting evidence becomes `human_required`; never auto-resolve money or identity by fuzzy text alone.

## Source profiles observed

### Daycoval
Bank-origin table evidence. Preserve bank table code/name, rate, term, upfront/deferred components and source version/date. Unknown coefficient/checklist remains null.

### Efetiva Mais
Commercial channel offer. Preserve Efetiva naming/conditions as channel evidence while mapping the underlying bank table canonically when deterministic.

### Bevicred
Commercial channel report may carry both Bevicred/channel code and bank code. Preserve both. Alçada Comercial/Executivo is source evidence and must not be silently interpreted as the tenant's payable commission.

## Safety

Raw rows are immutable. Normalization is versioned. Applying an accepted mapping is a separate domain action. Published financial/catalog rules require deterministic validation and appropriate approval.
