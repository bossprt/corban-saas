# CLAUDE LONG-RUN EXECUTION PROTOCOL — CORBAN OS

**Updated:** 2026-09-18
**Branch:** `architecture/corban-os-master-v2`
**Role:** Claude Code is the long-running local implementation executor. ChatGPT is architecture/control/review and may change the live Supabase schema. Git + project state files are the handoff bus; the user must not be used as a message courier between AIs.

## Bootstrap
Read `/AGENTS.md`, `/CORBAN-OS-PROJECT-CONTEXT-V2.md`, `/CORBAN-OS-MASTER-V2.md`, `/.ai/RULES.md`, `/.ai/DECISIONS.md`, `/.ai/CURRENT-TASK.md`, and `/CORBAN-CURRENT-STATE.md`. Then inspect Git, migrations, tests and actual code. Planned != implemented.

## Token/resource discipline
Before broad reading or repeated searches, inspect the locally available Claude Code plugins/skills/MCPs and use the cheapest appropriate capability. In particular, when actually installed and suitable, prefer Graphify for graph/codebase relationship discovery, Caveman for repository exploration/implementation workflows, Superpowers for structured engineering workflows, and context-mode for context compression/retrieval. Use Context7 or official docs for version-sensitive APIs. Do not invoke a plugin merely because it is named here: verify it is available and appropriate first. Reuse indexes/caches already present. Avoid repeatedly dumping large files into context; retrieve only relevant symbols/ranges. Parallelize independent read-only discovery/tests when safe.

## Long-run rule
Take a multi-block queue, not a one-file microtask. Continue autonomously through reversible local work. Do not stop after analysis. Implement, test, adversarially review, fix, retest, update state docs, commit and push the branch. Stop only for a true Human Gate: destructive/irreversible action, production publication, secret/credential, significant spend, or unresolved business decision that cannot be derived from project evidence.

## Coordination with ChatGPT
1. Pull before starting.
2. Treat live Supabase migrations as evidence; never edit an already-applied migration.
3. If ChatGPT has advanced live DB beyond repository migrations, create forward-only repository migrations/docs that faithfully mirror the verified live state; never fake migration history.
4. Keep `.ai/CURRENT-TASK.md`, `.ai/CHANGELOG.md`, `.ai/DECISIONS.md` and `CORBAN-CURRENT-STATE.md` current.
5. Push coherent checkpoints. ChatGPT will review GitHub rather than asking the user to relay Claude output.
6. Never work directly on `main`.

## Current execution queue
Bevicred live authentication is intentionally deferred; do not block on API key.

Execute the following as one long workstream, stopping only at a Human Gate:

### A. Reconcile integration infrastructure
Inspect live/repo state for the provider-agnostic integration contract and reconcile code/migrations for: adapter catalog, source bindings, import batch adapter lineage, execution ledger/runs/artifacts, secret guards, contract-version guards, canonical field mappings, immutable raw rows, normalized-row consistency and required indexes. Do not duplicate live objects. Add forward-only migrations only where repository history lacks the already-verified live state.

### B. 2Tech BuscaContrato adapter
Complete deterministic adapter `2tech/busca_contrato_file` for XLSX, XLS, CSV and HTML-exported-as-Excel. Provider is 2Tech; financial institution is a separate dimension. Preserve every raw field. Known source semantics include `StatusBancoCliente`, `StatusEmpresaVendedor`, `StatusProposta`, `ComissaoRepasseValor`; keep them independent. Blank/zero commission must not be interpreted as absence of revenue. Build mapping/version/fingerprint behavior and quarantine unknown schema changes.

### C. Canonical normalization
Close the stable cross-provider canonical contract for institution, agreement/convenio, product/modality, operation/form, contracting channel, term, rate, insurance/benefit, partner/channel, producer/digitizer, external proposal/table identity, source statuses and commission components. Provider-specific codes remain aliases/external identities, not canonical enums.

### D. Matching and conflict engine
Harden deterministic matching and human review for duplicate rows, same proposal from multiple sources, contradictory statuses, ambiguous external IDs, cross-tenant references, later corrections and replay. Preserve source evidence and never auto-publish financial truth from generic status text.

### E. Operational/financial integration
Connect approved evidence to existing proposal state evidence, component commercial snapshots, financial truth ledger and reconciliation. Cover expected -> reported -> received -> distribution/payable -> settled and adjustment/reversal paths without deleting history.

### F. Application UX
Advance Import Center and relevant Proposal/Finance views so an operator can see source, adapter, batch, raw lineage, normalized values, conflicts, matching decision, applied identity, evidence, financial/reconciliation consequence and errors. Keep sensitive commission/pricing visibility behind RBAC.

### G. Automated verification
Add/extend unit/contract/adversarial tests for: tenant A/B isolation; immutable raw rows; idempotent replay; duplicate file; API+file future coexistence; paid->cancelled/reversal; commission blank/zero; contradictory statuses; missing proposal identity; cross-tenant FK attempts; crash/retry semantics. Run typecheck/build/tests. Fix failures before finishing.

## Definition of Done for this run
- Repo and live DB integration architecture are reconciled without rewriting applied history.
- 2Tech adapter is production-shaped and deterministic, though final real-file validation may remain pending until a real BuscaContrato file is available.
- No fake financial/business data is persisted.
- Bevicred API remains deferred, not blocking.
- All safe local tests/builds pass.
- State/decision/changelog docs are updated.
- Changes are committed and pushed to `architecture/corban-os-master-v2`.
- Final handoff is written into `.ai/CURRENT-TASK.md` with exact completed work, failures, remaining gates and next executable task.


## Invocation policy — save weekly Claude quota
Claude is NOT the default executor. ChatGPT executes everything it can through connected GitHub/Supabase/Vercel tools first.

Invoke Claude only when the task genuinely requires local execution, installed local tooling/plugins, deep repository-wide local analysis, or a capability unavailable to ChatGPT.

When invoked:
- receive one long coherent queue instead of microtasks;
- inspect installed tools first and use the cheapest relevant capability;
- prefer Graphify/Caveman/Superpowers/context-mode/Context7 when installed and appropriate;
- reuse indexes/caches and symbol/range reads;
- avoid repeated full-file dumps;
- continue autonomously through implement -> test -> adversarial review -> fix -> retest -> docs -> commit/push;
- stop only at a true Human Gate.
