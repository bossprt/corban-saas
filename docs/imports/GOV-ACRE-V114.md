# Governo do Acre v114 — ingestion note

Source: `GOVERNO DO ACRE (2).xlsx`  
Source update: 12/06/2026  
Source version: 114

## What the source proves
- Agreement/context: Governo do Acre.
- Families: Margem; Tabelão Único combinando Portabilidade + Refin; Refin PL; Só Portabilidade.
- Exact table codes, rates, terms and flat/deferred commission percentages.
- Operational source rule: Tabelão Único requires the Portability Refin digitization; otherwise commission, RCO and CIP fee are reversed.

## First Vertical Slice candidate
`761111 - GOV ACRE 1 DIG - AOL`, transfer code `832110`, rate 2.50%, terms 48/60/72/84/96/120. Flat/deferred commission values are preserved in `data/source-evidence/gov-acre-v114.json`.

## Fields NOT proved by the source
The spreadsheet does not identify the bank, provider/master, installment coefficient, or document checklist. Those fields must not be guessed. Flat/deferred values are commission percentages, not loan coefficients.

## Import gate
No catalog row is published from this evidence until bank + provider are mapped to authoritative values. A simulation may later use a null coefficient as `manual_pending`, but the catalog route itself still requires bank/provider IDs.
