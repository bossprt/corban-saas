# CHANGELOG — CORBAN ENTERPRISE

Todas as mudanças notáveis deste projeto são documentadas aqui.

**Formato:** [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
**Versionamento:** [SemVer](https://semver.org/lang/pt-BR/)
**Compatível com Master:** v1.1

**Regras:**
- Toda sessão de trabalho deve adicionar uma entrada em `[Unreleased]` ou em uma nova versão.
- Entradas usam as categorias: `Adicionado`, `Alterado`, `Corrigido`, `Removido`, `Segurança`, `Depreciado`.
- Nunca editar entradas antigas — adicionar nova entrada.

---

## [Unreleased]

### Segurança — 18/09/2026

- Preparada, mas deliberadamente não aplicada, a migration de policies legadas → membership. O gate A/B exige identidades autenticadas reais em ambiente controlado.
- Confirmado banco vazio: 0 auth users, 0 organizations e 0 memberships; nenhum dado artificial foi inserido no projeto principal.

- Adicionado e aplicado `organization_memberships_v2` como fundação tenant V2 aditiva, preservando o legado.
- `organization_memberships` usa RLS e leitura autenticada apenas do próprio membership ativo; mutações não são concedidas ao papel `authenticated`.
- Helper V2 `is_active_organization_member` usa SECURITY INVOKER.
- Aplicada e versionada `optimize_membership_rls_auth_initplan` após advisor do Supabase apontar reavaliação de `auth.uid()` por linha.
- Advisor pós-correção mantém apenas alerta do helper legado `get_user_organization_id()`; não foi removido ainda para não quebrar policies legadas.

### Performance — 18/09/2026

- Aplicada e versionada migration aditiva com índices para FKs legadas de contracts/import_jobs/profiles. O advisor deixou de reportar FKs sem índice; avisos de índices ainda não usados são esperados em banco vazio.

### Documentação — 18/09/2026

- Baseline vivo do Supabase, plano Tenant/Auth/Membership V2 e contrato de teste de isolamento adicionados.


### Adicionado

- `docs/NEXT-VERSION-NOTES.md` — notas de breaking changes do Next.js 16.3.4, com base na documentação local (`node_modules/next/dist/docs/`).
- `.ai/BRIEFING-RETOMADA.md` — briefing para retomada entre sessões de IA.

### Alterado

- Estrutura de pastas consolidada em `src/app/` — removida pasta `app/` da raiz (boilerplate do `create-next-app`); movidos `globals.css` e `favicon.ico` para `src/app/`. Resolve ADR-0009.
- `tsconfig.json` corrigido: alias `@/*` agora aponta para `./src/*` (antes apontava para `./*`).

### Corrigido

- Import quebrado `./globals.css` em `src/app/layout.tsx` — o arquivo CSS estava em `app/` da raiz; agora está em `src/app/`.

---

## [0.1.1] — 2026-09-11 — Fundação de documentação para IAs

### Adicionado

- `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` — fonte de verdade conceitual revisada
- `CORBAN-CURRENT-STATE.md` — estado real do repositório
- `/.ai/RULES.md` — regras operacionais para IAs
- `/.ai/MASTER-CONTEXT.md` — contexto mínimo para IAs
- `/.ai/DECISIONS.md` — registro de decisões arquiteturais (10 ADRs aceitas + 7 pendentes)
- `/.ai/CHANGELOG.md` — este arquivo

### Alterado

- Nome do arquivo de estado: `AI-FACTORY-CURRENT-STATE.md` → `CORBAN-CURRENT-STATE.md`
- Estrutura de pastas consolidada em `src/app/` (ADR-0009) — execução pendente

### Corrigido

- Unicidade de CPF agora é parcial (`WHERE deleted_at IS NULL`) — ADR-0005

### Segurança

- Nenhuma alteração

---

## [0.1.0] — 2026-09-11 — Documento master inicial (v1.0)

### Adicionado

- `CORBAN-ENTERPRISE-MEMORIA-MASTER.md` v1.0 — visão inicial do produto
- Definição de multi-tenant
- Definição de RBAC inicial
- Roadmap com 14 fases
- Regra de Ouro (10 perguntas)

---

## [0.0.1] — 2026-09-09 — Setup inicial do repositório

### Adicionado

- `create-next-app` com Next.js 16.3.4
- TypeScript + Tailwind CSS 4
- Supabase instalado (`@supabase/ssr`, `supabase-js`)
- Estrutura inicial de auth (`middleware.ts`, `server.ts`)
- Página de login em `src/app/login/page.tsx`
- `PROJECT_CONTEXT.md` (desatualizado — será substituído)
- `AGENTS.md` (apenas aviso do Next 16)
- `CLAUDE.md` (aponta para `AGENTS.md`)
- Commit inicial no GitHub

---

# FIM

## 18/09/2026 — Vertical Slice V0 adversarial hardening
- Fixed invalid PL/pgSQL delimiters discovered during integrated review.
- Added FK-path indexes across Catalog, Proposal, Document Vault and Pipeline.
- Enforced same-customer PIX/account integrity and one primary account/PIX per customer.
- Made customer timeline and operational events append-oriented for privileged maintenance paths.
- Bound Proposal to Simulation customer/table snapshot; Proposal requires published table version and freezes commercial evidence after draft.
- Made customer document evidence immutable by version.
- Added linked-evidence validation, privileged waiver guard and transactional documents-ready digitization gate.
- Separated platform administrator authority from tenant admin; tenant provisioning is audited and platform-only.
- No staged vertical-slice migration was applied to the live database.


## 18/09/2026 — Autonomous Vertical Slice execution
- Reconciled `CORBAN-CURRENT-STATE.md` with V2 code/live evidence.
- Added `/app/simulacoes` with tenant-scoped customer + published-table simulation creation.
- Added proposal detail page with commercial snapshot, checklist readiness and operational state.
- Added `/app/documentos` read-only private-vault view; upload intentionally remains blocked until Storage RLS is live.
- Expanded `/app/operacao` to show digitization queue and operational cases.
- Added server-side CPF checksum validation and retained masked CPF list display.
- Prepared, but DID NOT APPLY live, `20260918_vertical_slice_domain_workflow_v0.sql`: one proposal per simulation, selected simulation immutability, proposal state graph, atomic simulation→proposal, checklist snapshot preparation, transactional send-to-digitization.
- Prepared, but DID NOT APPLY live, `20260918_document_storage_rls_v0.sql`: private 15 MiB document bucket, tenant/customer path isolation, authenticated SELECT/INSERT only, no evidence overwrite/delete.
- Added post-apply SQL contract `tests/security/vertical-slice-workflow-contract.sql`.
- Removed the earlier non-atomic UI path for simulation→proposal; current Preview fails closed until the transactional RPC is deployed.
- Vercel build confirmed success through commit `3718b230`.
- Live read-only inventory confirmed catalog/domain data is empty (0 banks/routes/tables/published versions/document types/stages/clients/simulations/proposals); no seed/data mutation was performed.
- Supabase advisors rechecked: 0 security ERROR; existing leaked-password WARN; platform service-role-only INFO; performance unused-index INFO expected on fresh/empty database.


## 18/09/2026 — Workflow/Storage live + document flow
- Applied authorized live migrations `vertical_slice_domain_workflow_v0` and `document_storage_rls_v0`.
- Executed `vertical-slice-workflow-contract.sql` successfully.
- Adversarial review caught checklist fail-open; committed/applied `vertical_slice_workflow_fail_closed_patch` so no published template or zero checklist items can mark a proposal ready.
- Connected Simulation→Proposal to atomic live RPC.
- Connected Proposal→prepare checklist and Proposal→digitization to live transactional RPCs.
- Implemented private document upload with tenant/customer path, MIME/size validation, SHA-256 duplicate detection and version metadata.
- Implemented proposal evidence linking and supervisor+ validation in application.
- Added app error boundary.
- Prepared (not applied) Operational State Machine and RBAC hardening migrations + post-apply contracts.
- Vercel build SUCCESS confirmed through `c9136e5f`.
