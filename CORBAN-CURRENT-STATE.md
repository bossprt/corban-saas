# CORBAN OS — CURRENT STATE

**Versão do estado:** 2.0
**Data:** 18/09/2026
**Branch ativa:** `architecture/corban-os-master-v2`
**Fonte conceitual:** `CORBAN-OS-MASTER-V2.md`

> Este arquivo registra apenas o que foi verificado como implementado. Histórico V1 permanece no Git.

## 1. Estado executável

- Next.js 16.3.4 + React 19 + TypeScript + Tailwind 4.
- App Router consolidado em `src/app/`.
- Next 16 routing usa `proxy.ts`; middleware raiz legado removido na branch V2.
- Supabase Auth real integrado.
- Preview Vercel conectado ao GitHub e build confirmado com status success.
- Usuário confirmou em 18/09/2026 que o Preview abriu login e que login real entrou em `/app`.
- `main` permanece fora do fluxo de desenvolvimento V2.

## 2. Tenant e segurança live verificados

- `organization_memberships` é vínculo explícito de tenant.
- contexto de app exige sessão + membership ativo + organization resolvida; falha fechado para `/access-pending`.
- gate A/B de isolamento entre dois tenants passou antes da migração legacy.
- RLS legacy migrado para membership.
- Vertical Slice V0 com RLS habilitado nas tabelas verificadas.
- advisor conhecido após hardening: 0 ERROR; WARN de Leaked Password Protection Disabled; INFO intencionais nas tabelas platform service-role-only.
- `service_role` não é exposta no browser.
- logout server-side implementado.
- CPF é mascarado na listagem de clientes.

## 3. Banco live / migrations aplicadas

Aplicadas e verificadas nesta linha V2:
- `20260917_organization_memberships_v2.sql`
- `20260918_admin_org_bootstrap_v0.sql`
- `20260918_migrate_legacy_rls_to_memberships.sql`
- `20260918_customer_360_foundation.sql`
- `20260918_product_catalog_v0.sql`
- `20260918_simulation_proposal_v0.sql`
- `20260918_document_vault_v0.sql`
- `20260918_digitization_pipeline_v0.sql`
- `20260918_vertical_slice_v0_post_apply_hardening.sql`
- `20260918_domain_primitives_v0.sql`
- `20260918_vertical_slice_domain_workflow_v0.sql`
- `20260918_document_storage_rls_v0.sql`
- `20260918_vertical_slice_workflow_fail_closed_patch.sql`

`create_customer_with_timeline(...)` está live e a Server Action de Customer usa a RPC atômica.

## 4. Vertical Slice V0 — implementação atual

| Capacidade | Banco | UI/Runtime |
|---|---|---|
| Login/Tenant | live | confirmado em Preview |
| Customer 360 | live foundation + RPC | lista + cadastro |
| Catálogo | live foundation | leitura |
| Simulação | live foundation | ainda sem fluxo UI |
| Proposta | live foundation | lista |
| Document Vault | live foundation | ainda sem fluxo UI |
| Digitação | live foundation + gate documental | leitura indireta |
| Mesa/Pipeline | live foundation | lista de casos |

Dashboard consulta contagens reais sob RLS.

## 5. Invariantes já materializadas

- relações tenant-scoped críticas usam FKs compostas onde definido.
- proposta referencia versão exata da tabela e congela snapshot comercial após draft.
- versão de tabela publicada é tratada como snapshot imutável.
- requisitos documentais preservam snapshot.
- proposta só entra em digitação quando pronta e requisitos obrigatórios estão validados/waived.
- checklist publicado sem requisitos instanciados falha fechado.
- eventos operacionais são append-oriented para authenticated.
- authenticated não recebe DELETE nos domínios do vertical slice.

## 6. Lacunas reais

- Simulação possui UI segura e criação de Proposal usa RPC atômica live.
- Checklist e envio para digitação usam RPCs live; checklist falha fechado sem template publicado/itens.
- Document Vault possui bucket privado live, upload versionado/hash e vínculo/validação de evidência.
- Proposal detail, Document Vault read-only e fila operacional estão implementados no Preview.
- state machines de Proposal/Operational ainda precisam de primitives transacionais e RBAC mais estrito.
- Storage bucket/object policies do Document Vault ainda não estão implementadas.
- waiver via service_role ainda precisa de primitive auditada antes de uso real.
- simulation selecionada ainda precisa de proteção de imutabilidade completa.
- catálogo ainda não possui fluxo seguro de publicação/admin na UI.
- testes automatizados de aplicação/E2E não estão instalados; existem contratos SQL de segurança/schema no repositório.
- proteção de senha vazada do Supabase Auth permanece pendente de configuração.
- service-role da Vercel não é necessária ao fluxo normal; endpoint platform-admin depende dela e não deve ser usado no Preview sem configuração controlada.

## 7. Próximo trabalho

Completar a primeira fatia demonstrável em ordem:
1. primitives e UI de Simulação → Proposta;
2. Document Vault/checklist e preparação de Storage policies;
3. primitive transacional Send to Digitization;
4. transitions controladas da mesa operacional + timeline;
5. RBAC e tratamento de erro;
6. testes/contratos adicionais;
7. validação Preview.

Novas migrations podem ser preparadas/commitadas, mas não aplicadas live sem Human Gate específico. Nesta execução foram preparadas `20260918_vertical_slice_domain_workflow_v0.sql` e `20260918_document_storage_rls_v0.sql`; ambas permanecem NÃO APLICADAS.


## 8. Próximo Human Gate (18/09/2026)
Preparadas, mas NÃO APLICADAS:
- `20260918_operational_state_machine_v0.sql`
- `20260918_rbac_hardening_v0.sql`

A primeira conclui as transições controladas da Mesa sem permitir marcação manual de PAID. A segunda move enforcement de RBAC crítico para o banco.

## 9. Pipeline/RBAC live (18/09/2026)
- Operational State Machine V0 aplicada e contract validado.
- RBAC hardening V0 aplicado e contract validado.
- Helper SECURITY DEFINER teve EXECUTE direto removido após advisor.
- Mesa usa transição transacional; PAID manual é proibido.
- Diagnóstico de prontidão do tenant disponível em `/app/configuracao`.
- Bloqueio atual não é técnico: faltam dados comerciais/operacionais válidos para configurar o tenant e executar E2E real.


## 10. MVP closure wave — 18/09/2026
- Importação: CSV, XLS HTML e XLSX nativo; SHA-256/idempotência; normalização; matching determinístico automático; revisão humana fail-closed.
- Fontes financeiras: semântica persistida e congelada após uso; adapters governados para produção/status, comissão reportada, pagamento recebido e pagamento da rede.
- Financeiro: publicação por evidência exige decisão aprovada+aplicada e match exato; reconciliação é atualizada automaticamente.
- Comercial: rota de proposta pode ser congelada por RPC; splits são snapshots por componente (à vista/diferido/antecipação/bônus), sem assumir split uniforme.
- Operação: transição para PAID exige evidência operacional de importação; texto bruto não é convertido automaticamente em PAID.
- Segurança: RPCs críticos SECURITY INVOKER, anon sem EXECUTE; guards impedem bypass de fatos financeiros, snapshots comerciais e PAID; último Security Advisor executado com 0 ERROR.
- Performance: índices dos novos FKs de snapshots por componente aplicados.
- Nenhum fato financeiro/comercial real foi fabricado durante implementação.
- Preview verde anterior: commit 2466f0c. A onda atual ainda precisa de novo build/typecheck Vercel; status de deployment não está chegando pela integração GitHub usada pelo agente.
- Configuração externa pendente antes de produção real: habilitar Supabase Auth Leaked Password Protection.


## 11. LONG-RUN integração — 18/09/2026
- Repositório espelha agora todas as migrations live do contrato de integração (A). Não aplicadas no remoto por esta execução.
- Implementado no código: adapter 2Tech determinístico para CSV/XLS-HTML/XLSX, contrato canônico e motor de conflitos, tela de lote com linhagem/conflitos, gates de RBAC para dados de comissão. Validação com arquivo real BuscaContrato continua pendente; aliases de colunas de identidade são provisórios.
- Testado: 31 testes unitários, typecheck, lint (0 erros) e `next build` locais. Contrato SQL de integração passou no banco live (somente leitura).
- Não implementado/aplicado (Human Gate): reversões governadas, netting de reversões na conciliação, revogação de TRUNCATE/REFERENCES/TRIGGER, vínculo de adapter ao lote. Ver `.ai/CURRENT-TASK.md`.


## 12. LONG-RUN parte 2 — 19/09/2026
- Live: privilégios TRUNCATE/REFERENCES/TRIGGER revogados (aplicado pelo ChatGPT). Todo o resto de `20260919_*` está apenas preparado.
- Bloqueadores live descobertos em sondagem rollback-only: RBAC helper sem EXECUTE para `authenticated` e `digest()` não qualificado. Enquanto não corrigidos, escritas com RBAC, ingestão de arquivo e publisher de evidência falham para usuários reais.
- Testado localmente: 48 testes unitários, tsc, eslint (0 erros), `next build --webpack`; harnesses SQL rollback-only passam com as migrations preparadas executadas na mesma transação.


## 13. LONG-RUN parte 3 — 19/09/2026
- LIVE: revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1.
- NOT LIVE: import_batch_adapter_lineage_v1 (reescrita) e as migrations novas (ver CHANGELOG). Sem elas, matching de importação e aplicação de vínculo aprovado NÃO funcionam para usuário real (min(uuid), policy ausente, identidade duplicada por caixa) e a leitura financeira ainda é aberta a `agent` via API.
- App: `/app/financeiro` (lista + ledger + reversão + resolução) implementado; depende de `publish_financial_reversal` e do guard de reconciliation cases, já LIVE.


## 14. Closure wave — 20/09/2026
- LIVE (confirmado por `list_migrations`): revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1, fix_import_matching_uuid_aggregate_v1, import_apply_rls_v1, import_identity_case_normalization_v1, rbac_helper_security_invoker_v1, financial_read_rbac_v1, import_batch_adapter_lineage_v1.
- NOT LIVE: import_conflicts_v1, column_security_and_tenant_derivation_v1, reconciliation_resolution_immutability_v1, leads_v1.
- App já preparado para os dois estados (antes/depois) em lote de importação, proposta, clientes, leads e conflitos. Multi-org e escopo de tenant do client são código e já valem hoje; RPCs de tenant-por-recurso dependem da migration.


## 15. Operational integration wave — 21/09/2026
- Seção 14 está superada: import_conflicts_v1, column_security_and_tenant_derivation_v1, reconciliation_resolution_immutability_v1, leads_v1 e leads_customer_fk_index_v1 estão LIVE (aplicadas pelo ChatGPT; Security Advisor 0 WARN/0 ERROR).
- LIVE (aplicadas pelo ChatGPT em 19/09/2026): `20260921_integration_run_state_machine_v1` (registrada como 20260919035427) e `20260921_operational_pipeline_write_hardening_v1` (20260919035447). Não reaplicar.
- Código pronto: `src/lib/integrations/{contract,executor,repository,fake-provider,registry,redact,observability,view-state}.ts`, `/app/integracoes` (degrada corretamente antes da migration).
- Nenhum provider real habilitado. 2Tech aguarda arquivo real; Bevicred DEFERRED.


## 16. Worker + governance wave — 22/09/2026
- LIVE: tudo até `operational_pipeline_write_hardening_v1` (seção 15 corrigida).
- LIVE (aplicada pelo ChatGPT como 20260919044054 worker_governance_v1): inclui o HOTFIX de `transition_operational_case` (a RPC estava quebrada no live entre o hardening da esteira e esta migration). Corrigida e provada em 125 checagens. Não reaplicar.
- Código pronto (aplica-se sozinho quando a migration existir): worker server-only, dispatch, cancel/retry/reexecução, `/app/integracoes` com ações. Sem cron; sem provider real; Bevicred DEFERRED; 2Tech awaiting_real_file.


## 17. Live regression + closure — 23/09/2026
- LIVE (nada novo aplicado por esta onda): tudo até `worker_governance_v1`. Suítes rerodadas contra o estado LIVE (sem preludes): worker governance 125, integration runs 111, operational E2E 72, financial E2E 93, leads 47 — todas ALL PASS; advisors: segurança 0 WARN/0 ERROR (2 INFO intencionais), performance só INFO (índices não usados em banco vazio; conexões de auth).
- NOT LIVE (preparadas, harness rollback-only verde): `20260923_worker_dispatch_hardening_v1` (histórico de tentativas, dispatch escopado, mensagem hostil não trava) e `20260924_confirm_paid_replay_v1` (replay idempotente de PAID, 18 checagens).
- IMPLEMENTED (código, ativa-se sozinho após as migrations): despacho por adapter, orçamento de tempo, histórico e linhagem na UI, mensagens de erro classificadas em /app/operacao e /app/integracoes.
- BLOCKED: 2Tech (arquivo real). DEFERRED: Bevicred. HUMAN GATE: aplicar as 2 migrations; segredo + agendador do worker; regra de comissão visível ao agent.


## 18. Pilot readiness wave - 24/09/2026
- LIVE: tudo ate `20260924_confirm_paid_replay_v1` (worker_dispatch_hardening_v1 e confirm_paid_replay_v1 aplicadas pelo ChatGPT). Regressao LIVE rerodada nesta onda: dispatch hardening 24/24 sem prelude; inventario SECURITY DEFINER = 8; advisors 0 WARN/0 ERROR; zero residuo.
- NOT LIVE (preparada, harness rollback-only 131/131 + E2E de piloto 45/45): `20260925_team_access_lifecycle_v1` (convites, RPCs de papel/status, auditoria, grants/guard de memberships).
- IMPLEMENTED (codigo, dorme ate a migration): `/app/equipe`, aceite de convite, `/auth/definir-senha`, `/auth/confirm`.
- IMPLEMENTED (ativo): menu por perfil, dashboard piloto, `canViewCommission`, rotulo LOCAL/TESTE, painel de prontidao, `/api/health`.
- EXTERNAL GATES: Auth Site URL/Redirect URLs + SMTP; segredo e agendador do worker. PRODUCT DECISION: comissao visivel ao agente. BLOCKED: 2Tech (arquivo real). DEFERRED: Bevicred.
