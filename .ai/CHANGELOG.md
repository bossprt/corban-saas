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

### Adicionado — 26/09/2026 (Commercial Model V3)

- Migration preparada `20261002_commercial_model_v3_foundation_v1` (aditiva; não aplicada): `contract_types`, `national_agreement_templates` (27 governos/DF + 26 prefeituras de capitais), catálogo do tenant (`organization_banks/providers/agreements`, `commission_groups`), rota V3, `commercial_conditions` + comissão/participações por grupo, `save_commercial_condition`, `create_simulation_for_condition`.
- Política de repasse (`payout_policies/versions/items`, versões imutáveis, base bruta/líquida, override rastreável) e Origem da Produção Própria/Terceiro (doc V3 §19.3/§20), na mesma migration ainda não aplicada.
- `/app/comercial`, importação CSV/XLSX com uma coluna por grupo de comissão e prévia sem gravar, simulação por condição, configuração V3, testes unitários e harness SQL rollback-only.

### Segurança — 26/09/2026

- Corrigido teto de comissão: era a SOMA dos grupos; agora é POR GRUPO (grupos são vendedores alternativos, como no exemplo do doc V3).
- Unicidade de nomes por `lower(btrim(name))` (espaços não burlam duplicidade); condições congeladas após publicar; comissão e participações só supervisor+; sem Float.
- Teste de arquitetura `worker-hardening` alinhado com os importadores reais do admin client (deriva pré-existente, módulos server-side).
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


## 18/09/2026 — Operational state machine + RBAC live
- Applied authorized `operational_state_machine_v0` and `rbac_hardening_v0`.
- Both post-apply SQL contracts passed.
- Supabase advisor identified callable SECURITY DEFINER role helper; applied corrective `rbac_helper_exposure_patch`, removing direct authenticated/anon EXECUTE while preserving RLS use.
- Connected Mesa UI to transactional operational transitions.
- Manual PAID remains prohibited; financial truth is not inferred from operational clicks.
- Added tenant readiness diagnostics at `/app/configuracao`.
- Confirmed live data gate: no banks/tables/checklists/stages/simulations/proposals exist, so no truthful E2E can be fabricated.

### Adicionado — 18/09/2026 (execução LONG-RUN, blocos A–G)
- Migrations espelho (já live) do contrato de integração: catálogo de adapters, bindings, execution ledger, guards de segredo/contrato, mapeamentos canônicos, imutabilidade de raw rows e `dedupe_financial_evidence_insert_policy`.
- Adapter `2tech/busca_contrato_file` (`src/lib/imports/twotech.ts`), contrato canônico (`canonical.ts`) e motor de conflitos (`conflicts.ts`).
- Runner de testes unitários sem novas dependências (`npm run test:unit`, 31 testes) e contratos SQL `integration-contract-v1-contract.sql` e `financial-reversal-paths-contract.sql`.
- Tela de lote: linhagem (adapter/contrato/schema), conflitos entre lotes/fontes do mesmo tenant e evidência de origem por linha.

### Segurança — 18/09/2026 (execução LONG-RUN)
- Comissão e financeiro ocultos para papéis abaixo de supervisor no lote, dashboard, proposta e `/app/financeiro` (gate no servidor sobre RLS).
- PREPARADAS, NÃO APLICADAS: `20260919_financial_reversal_paths_v1`, `20260919_revoke_excess_table_privileges_v1`, `20260919_import_batch_adapter_lineage_v1`.

### Corrigido — 18/09/2026
- Tipagem de `exceljs` (`Buffer`) em `xlsx.ts`; `package-lock.json` sincronizado com `exceljs` já declarado no `package.json`.

### Adicionado — 19/09/2026 (LONG-RUN parte 2)
- Pipeline genérico `prepareImport` (`src/lib/imports/pipeline.ts`) com erros explícitos; a action de ingestão o utiliza e rejeita mesmo arquivo já importado em outra fonte.
- Calculadora exata de comissão esperada (`src/lib/commission`), validada contra `numeric` do Postgres; política RBAC central `atLeast()` (`src/lib/rbac.ts`).
- Harnesses SQL rollback-only: `financial-reversal-behavior-rollback.sql` (57 checagens) e `reconciliation-cases-hardening-rollback.sql` (10).
- Auditoria `docs/audits/AUDIT-2026-09-19-TENANT-RESOLUTION-AND-LIVE-BLOCKERS.md`.

### Corrigido — 19/09/2026
- `parseHtmlTable` falhava com tabelas de menos de 3 colunas; matcher TS agora compara instituição sem diferenciar caixa (como o SQL).
- Modelo de reversão (partial reversals) e lock de concorrência reescritos (migration preparada).

### Segurança — 19/09/2026
- PREPARADAS, NÃO APLICADAS: `20260919_restore_rbac_helper_execute_v1`, `20260919_fix_digest_search_path_v1`, `20260919_reconciliation_cases_write_hardening_v1`, `20260919_financial_reversal_paths_v1` (reescrita), `20260919_import_batch_adapter_lineage_v1` (reescrita).
- JÁ APLICADA externamente (ChatGPT): revogação de TRUNCATE/REFERENCES/TRIGGER (`20260919_revoke_excess_table_privileges_v1`).

### Adicionado — 19/09/2026 (LONG-RUN parte 3)
- `/app/financeiro`: lista de casos com filtros e `/app/financeiro/casos/[id]` com ledger ORIGINAL → REVERSÕES → SALDO LÍQUIDO, evidência/fonte/referência, reversão parcial/total via RPC e resolução humana (só status + justificativa; resolved_by/at do banco). Valores como texto decimal (sem float).
- `src/lib/finance/ledger.ts`, `prepareImport` com detecção de formato por conteúdo, `conflict-persist.ts`, vetores de comissão (60 aleatórios vs Postgres, 0 divergências).
- Harnesses SQL rollback-only: E2E financeiro (44), tenant A/B adversarial (19), conflitos (24), helper+lineage (32).
- Auditorias `docs/audits/AUDIT-2026-09-19-SECURITY-DEFINER.md` e `AUDIT-2026-09-19-E2E-LIVE-BLOCKERS.md`.

### Segurança — 19/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260919_rbac_helper_security_invoker_v1`, `20260919_import_batch_adapter_lineage_v1` (reescrita: schema private), `20260919_financial_read_rbac_v1`, `20260919_fix_import_matching_uuid_aggregate_v1`, `20260919_import_apply_rls_v1`, `20260919_import_identity_case_normalization_v1`, `20260919_import_conflicts_v1`.
LIVE (aplicadas pelo ChatGPT): `revoke_excess_table_privileges_v1`, `restore_rbac_helper_execute_v1`, `fix_digest_search_path_v1`, `financial_reversal_paths_v1`, `reconciliation_cases_write_hardening_v1`.

### Corrigido — 19/09/2026
- Ingestão rejeita mesmo arquivo já importado em outra fonte; extensão do arquivo não decide mais o parser (conteúdo decide).

### Adicionado — 20/09/2026 (closure wave)
- `/organizacao` (seleção explícita de organização), `resolveActiveMembership`/`scopeToOrganization`, `/app/leads`, executor de integrações outbound com adapter fake, harnesses SQL rollback-only (E2E financeiro agora com colunas/multi-org, leads 29, resolução 17).
- Auditoria `docs/audits/AUDIT-2026-09-20-CLOSURE-WAVE.md`.

### Segurança — 20/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260920_column_security_and_tenant_derivation_v1`, `20260920_reconciliation_resolution_immutability_v1`, `20260920_leads_v1` (+ `20260919_import_conflicts_v1` ainda pendente).
Achados: leitura por agent de colunas econômicas; role NULL contornando `not in` nos readers privados (corrigido antes de aplicar); nota/autor/data de resolução reescritos com status inalterado; refresh órfão de caso resolvido; 9 funções com `limit 1` de membership.

### Adicionado — 21/09/2026 (operational integration wave)
- Executor outbound reescrito sobre `RunRepository` (Supabase + gêmeo em memória), contrato de provider com `CapabilityManifest`, gate de evidência, redactor, logger whitelist, provider fake roteirizado (11 comportamentos), registro de homologação, `/app/integracoes`.
- Harnesses: `integration-runs-rollback.sql` (111), `operational-e2e-rollback.sql` (Lead→…→Reconciliation com todas as roles).
- Auditoria `docs/audits/AUDIT-2026-09-21-OPERATIONAL-INTEGRATION-WAVE.md`; contrato de homologação `docs/integrations/2TECH-BUSCACONTRATO-HOMOLOGATION.md`.

### Segurança — 21/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260921_integration_run_state_machine_v1`, `20260921_operational_pipeline_write_hardening_v1`.
Achados: esteira gravável por qualquer membro (forjar histórico / caso `paid`); ledger de integração sem máquina de estados; payload bruto de provider legível por todo membro; segredo persistível em metadata/artefato/erro.

### Adicionado — 22/09/2026 (worker + scheduler + governed retry/cancel)
- `src/lib/integrations/{worker,worker.server,metrics}.ts`, rota `POST /api/integrations/dispatch` (Bearer, desabilitada sem segredo), ações de servidor `retryRun` / `cancelRun` / `reexecuteRun`, UI `/app/integracoes` com Nova tentativa / Cancelar / Nova execução, RunRepository com `enqueue` / `listDispatchable` / `reexecute`.
- Harness `tests/security/worker-governance-rollback.sql`; testes unitários `worker.test.ts` (21).
- Auditoria `docs/audits/AUDIT-2026-09-22-WORKER-GOVERNANCE-WAVE.md`; deploy do worker em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Segurança — 22/09/2026 (PREPARADA, NÃO APLICADA)
`20260922_worker_governance_v1`: corrige `transition_operational_case` (regressão do hardening LIVE), governa escrita de `proposals_v2` e `customer_timeline_events`, adiciona enqueue/dispatch/reexecução.

### Adicionado — 23/09/2026 (regressão LIVE + prova do worker + prontidão de scheduler)
- Dispatch como função pura (`handleDispatchRequest`), guard do fake por allow-list, despacho escopado por adapter, orçamento de tempo do ciclo, histórico de tentativas, erros classificados na UI de operação e de integrações, linhagem visual (execução original / nova execução / motivo).
- Testes: `worker-hardening.test.ts` (arquitetura, dispatch auth, matriz do guard, backpressure/starvation, cancel vs fencing, histórico, repositório real sobre ponte RPC, contrato RPC×SQL).
- SQL: harnesses rodados contra o estado LIVE sem preludes; novos `worker-dispatch-hardening-rollback.sql` e `proposal-paid-evidence-rollback.sql`.
- Docs: `docs/audits/AUDIT-2026-09-23-LIVE-REGRESSION-AND-CLOSURE.md`, `docs/PILOT-GAP-ANALYSIS.md`, seção de scheduler em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Segurança — 23/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260923_worker_dispatch_hardening_v1`, `20260924_confirm_paid_replay_v1`. Achados: starvation de dispatch por adapters irrecuperáveis; histórico de tentativas apagado no retry; mensagem de falha "secreta" travava o run; replay de PAID não idempotente.

### Adicionado - 24/09/2026 (onda de prontidao para piloto)
- Equipe (`/app/equipe`): convidar, reenviar/cancelar convite, alterar perfil, desativar/reativar acesso, trilha de auditoria. Fluxo de convite completo: `/auth/definir-senha`, `/auth/confirm`, aceite no `/access-pending` e `/organizacao`.
- Menu por perfil, dashboard piloto (leads, integracoes com atencao, conciliacoes pendentes, estados `indisponivel`), politica central `canViewCommission`, rotulo `LOCAL / TESTE`, painel de prontidao do worker, `GET /api/health`.
- Testes: `team-access-rollback.sql` (131), `pilot-e2e-rollback.sql` (45), unit 171. Runbook de ativacao e modos de falha do worker/scheduler em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Seguranca - 24/09/2026 (PREPARADA, NAO APLICADA)
`20260925_team_access_lifecycle_v1`. Achado: nao havia caminho governado para gerir equipe e o e-mail de convite nao tinha handler no app.

### Adicionado - 24/09/2026 (fechamento do piloto, onda 2)
- Recuperacao de senha (`/login/recuperar`), historico de tentativas por execucao, painel "Precisa da sua atencao", rotulos da esteira, cache do health, dashboard sem consultas fora do perfil, simulacao via RPC (com fallback temporario).
- Runbooks: `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md`; cadencia do worker em `docs/integrations/WORKER-DEPLOYMENT.md`.
- Testes: unit 189, `simulation-governance-rollback.sql`, `pilot-e2e-v2-rollback.sql` (39), `membership-policy-merge-rollback.sql` (12); regressao LIVE: equipe 83, paid replay 15.

### Seguranca - 24/09/2026 (PREPARADAS, NAO APLICADAS)
`20260926_simulation_governance_v1` (simulacoes forjaveis com comissao arbitraria) e `20260927_membership_select_policy_merge_v1` (advisor WARN de performance).

### Adicionado - 25/09/2026 (fechamento do piloto, onda 3: 1 operador real)
- Feedback humano por codigos, upload com verificacao de bytes, busca, menu por perfil, dashboard do operador, rotulos de proposta/simulacao, botoes anti duplo clique, validacao de CPF.
- Worker: sweep de runs orfaos antes de listar. Documentos: `docs/pilot/*` (checklist, setup do Owner, guias do operador e do supervisor), auditoria da onda 3.
- Testes: unit 211; `revoked-actor-dispatch-rollback.sql` (6 bug / 22 corrigido); chain E2E LIVE 35.

### Seguranca - 25/09/2026 (PREPARADA, NAO APLICADA)
`20260928_revoked_actor_dispatch_v1`: starvation do dispatch por runs de ator revogado CONFIRMADA.

### Adicionado - 25/09/2026 (onda 4: implantacao e tenant)
- `/app/catalogo` (rotas, tabelas, versoes, checklists, etapas padrao) e `/app/configuracao` (status da configuracao); rota de plataforma para o catalogo de referencia; bootstrap de organizacao com CNPJ e guarda de nome parecido; env fail-closed; `npm run preflight`; limite de upload 4 MB.
- Docs: `docs/deployment/*` (variaveis, auth/SMTP, runbook de implantacao, rollback, drift), `docs/pilot/SMART-HUMAN-ACCEPTANCE-TEST.md`, `SMART-PILOT-INCIDENTS.md`.
- Testes: unit 229; `catalog-publish-rollback.sql` 40/40.

### Seguranca - 25/09/2026 (PREPARADA, NAO APLICADA)
`20260929_catalog_publish_v1`: publicar tabela/checklist era impossivel sem SQL; INSERT permitia versao ja publicada.

### Adicionado — 20/09/2026 (Next wave V3, preparado)

- CEP automatico no cadastro/edicao de cliente (rota `/api/cep`, ViaCEP, sem chave); passo a passo em `/app/comercial`.
- Migrations preparadas (nao aplicadas): `20261004_commercial_bulk_import_v1` (importacao atomica), `20261005_ai_import_metering_v1` (memoria de mapeamento + creditos/metering de IA), `20261006_action_center_v1` (Central de atencao); harnesses rollback-only.
- Biblioteca `src/lib/ai-import` (provider-agnostic, adapter Gemini sem chave) e `src/lib/attention-rules.ts`; pagina `/app/atencao`.
- Auditoria e desenho da integracao de payout: `docs/audits/AUDIT-2026-09-20-NEXT-WAVE-V3.md`.


### Alterado — 20/09/2026 (reestruturação de produto V1)
- Menu principal reorganizado por áreas de negócio.
- Adicionados hubs CRM, Operacional, Cadastros e Relatórios usando módulos já existentes.
- Nenhum DDL, dado real, secret ou regra financeira alterados.
- Protocolo de tripla revisão e economia de Claude registrado em RULES/CLAUDE-LONG-RUN.
- Roadmap consolidado em `docs/PRODUCT-UX-RESTRUCTURE-V1.md`.


### Auditado — 20/09/2026 (pré-Wave B)
- Schema LIVE revisado em modo somente leitura.
- Confirmado reuso possível de commercial_entities/relationships/channels, network_split_rule_versions e commission_rule_components.
- Lacunas registradas: vendedor/perfil comercial e fatores versionados.
- Nenhuma DDL aplicada; Claude não utilizado.


### Preparado — 20/09/2026 (Seller/SUB + Fatores)
- `20261007_seller_commercial_profile_v1.sql`: Grupo de Vendedor ≠ Grupo de Comissão, cadastro PF/PJ/SUB e regra SUB versionada.
- `20261008_commercial_factors_v1.sql`: fatores daily/fixed, batches versionados e resolver para CRM.
- Dois contratos SQL adicionados.
- Ambos executados rollback-only sem erro; zero persistência.
- Publicação financeira/configuração protegida por RPC; inserts autenticados começam em draft.
- Vercel READY; Claude não utilizado.
- Aguardando autorização explícita para DDL LIVE.


### LIVE — 20/09/2026 (Seller/SUB + Fatores)
- Aplicadas `seller_commercial_profile_v1` e `commercial_factors_v1`.
- Contratos pós-apply passaram.
- Security advisor sem WARN/ERROR novo.
- UI de Vendedores/SUB e Fatores adicionada; importação de fatores CSV/XLSX inicial disponível.
- Nenhum Claude utilizado.


### Preparado — 20/09/2026 (Componentes + Tipos de Contrato)
- Preparada camada component-aware de comissão: À Vista, Diferido, Bônus 1/2/3, Plástico e Seguro fixo.
- Suporte preparado para % e R$, regras por Grupo de Comissão, desconto/imposto e escopo organização/banco/convênio/tabela.
- Preparado gerenciamento tenant-aware de Tipo de Contrato com flags de esteira/comissão.
- Preparado pacote de índices das novas FKs de Seller/SUB/Fatores.
- Três contratos rollback-only passaram; zero persistência.
- Claude não utilizado.


### LIVE — 20/09/2026 (Componentes + Tipos de Contrato)
- Componentes de comissão, tipos tenant-aware e índices adicionais aplicados LIVE.
- Refin/Portabilidade incluído no catálogo global.
- Contratos pós-apply passaram; security advisor sem WARN/ERROR novo.
- UI de Tipos de Contrato e regras por componente iniciada.
- Claude não utilizado.


### Preparado — 20/09/2026 (Smart Commercial Import V1)
- Parser determinístico de planilha comercial adicionado.
- Modelo XLSX dinâmico passa a usar nomes reais dos Grupos de Comissão.
- RPC atômica preparada para catálogo/tabela/condições/componentes/fatores.
- Generic Repasse 1/2/3 é tratado como ambiguidade, não como grupo.
- 20261012 passou em rollback-only; zero persistência.
- Claude ainda não utilizado.


### LIVE/UX — 20/09/2026 (Smart Import)
- `smart_commercial_import_v1` aplicado LIVE.
- Contract pós-apply passou; security advisor sem WARN/ERROR novo.
- Tela guiada de importação inteligente adicionada.
- CSV/XLSX com prévia, perguntas condicionais e confirmação antes do RPC atômico.
- Repasse 1/2/3 legado nunca é associado silenciosamente a Grupo de Comissão.
- Tabela fica em rascunho após a carga.
- Claude não utilizado até este ponto.


### Estabilizado — 20/09/2026 (Smart Import build)
- Produção Vercel novamente READY.
- Experimento de cálculo econômico detalhado na prévia revertido após erro de build; core Smart Import preservado.
- Banco LIVE não sofreu rollback nem alteração adicional.
- Próximo trabalho transferido para Claude apenas por necessidade real de ambiente local: XLS legado/PDF + dependências + testes com arquivos reais.

### Adicionado — 20/09/2026 (Smart Import XLS + PDF)

- Leitura de `.xls` legado (`@e965/xlsx`) e de PDF com camada de texto (`unpdf`) para o Smart Commercial Import, reaproveitando o mesmo parser.
- Guardas de arquivo: formato por magic bytes, inspecao de zip, limites de tamanho/linhas/colunas, nome seguro.

### Segurança — 20/09/2026

- XLSX com mais de 1.000 linhas era cortado em silencio; agora recusado acima do teto. Coluna de dinheiro nao reconhecida recusa o arquivo. Datas de calendario invalidas recusadas.
