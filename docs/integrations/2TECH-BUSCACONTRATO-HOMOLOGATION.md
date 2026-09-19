# 2Tech / BuscaContrato — homologation contract

Status: **BLOCKED — waiting for a real export file.** Nothing here may be marked done with synthetic data.

The boundary is ready: adapter `2tech/busca_contrato_file` (contract 1.0.0), manifest in `src/lib/integrations/registry.ts`, schema fingerprint
mechanism and quarantine in `src/lib/imports/twotech.ts`. The list `KNOWN_TWOTECH_SCHEMA_FINGERPRINTS` is empty on purpose, so every schema is
reported as `unverified`.

## Acceptance checklist (all required to flip the registry entry to `homologated`)
1. A real BuscaContrato file (XLSX / XLS / CSV / HTML-as-Excel) is provided by the operator, outside the repository or with commercial data removed.
2. Its header set is fingerprinted (`schemaFingerprint`) and the fingerprint is added to `KNOWN_TWOTECH_SCHEMA_FINGERPRINTS` in a reviewed commit.
3. Every provisional alias (`PROPOSAL_NUMBER_FIELDS`, `INSTITUTION_FIELDS`, `TABLE_CODE_FIELDS`, …) is confirmed or removed against the real header names. No column is invented.
4. `StatusBancoCliente`, `StatusEmpresaVendedor`, `StatusProposta` and `ComissaoRepasseValor` are verified as independent dimensions; blank vs zero commission behaviour is confirmed with real rows.
5. The same file in the four formats yields identical normalized rows (existing unit test pattern, with real-shaped fixtures that carry no customer data).
6. Import → matching → decision → apply → evidence → ledger is replayed rollback-only for that file; duplicate file and correction replay behave as specified.
7. A schema change (new/removed column) lands in quarantine and blocks publication until a human approves.
8. `usability('2tech/busca_contrato_file')` returns `usable` only after 2–7 are green.

## Explicitly out of scope until then
Any external call, any credential, any Bevicred work, and any use of provisional aliases as if they were definitive.
