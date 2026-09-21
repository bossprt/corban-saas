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


## 19. Pilot closure wave 2 - 24/09/2026
- LIVE: tudo ate `20260925_team_access_lifecycle_v1` (aplicada como 20260919160840). Regressao LIVE nesta onda: equipe 83/83, paid replay 15/15, pilot E2E v2 39/39 (com prelude da simulacao); DEFINER = 8; advisors de seguranca 0 WARN/0 ERROR; performance: 1 WARN novo (`multiple_permissive_policies` em organization_memberships, causado pela migration de equipe) + INFO de indices nao usados (banco vazio).
- NOT LIVE (preparadas, harness rollback-only verde): `20260926_simulation_governance_v1` (create_simulation RPC, guard, grants por coluna) e `20260927_membership_select_policy_merge_v1` (uma policy SELECT).
- IMPLEMENTED: recuperacao de senha, historico de tentativas, painel de atencao, rotulos da esteira, cache do health.
- EXTERNAL GATES: Auth (Site URL, Redirect URLs, SMTP, politica de senha), segredo+agendador do worker. PRODUCT DECISION: comissao visivel ao agente. BLOCKED: 2Tech. DEFERRED: Bevicred.


## 20. Pilot closure wave 3 - 25/09/2026
- LIVE: tudo ate `20260927_membership_select_policy_merge_v1` (20260919183522) e simulation governance (20260919183518); `legacyInsert` removido. Verificado: DEFINER 8 (anon 0), advisors de seguranca 0 WARN/0 ERROR, zero residuo, organizacao Smart Promotora NAO existe (2 orgs de teste, 1 administrador de plataforma ativo).
- NOT LIVE (harness verde): `20260928_revoked_actor_dispatch_v1` (starvation por ator revogado CONFIRMADA no LIVE; correcao 22/22).
- IMPLEMENTED: feedback por codigos, sniffing de upload, busca, menu por perfil, dashboard do operador, labels, sweep no worker (tolera banco sem a funcao).
- Regressao LIVE desta onda: chain E2E 35/35. Nao rerodadas: leads, operacional, integration runs, worker governance, financeiro, conflicts, reconciliation, paid evidence, team (nenhum objeto LIVE delas mudou).
- NAO FEITO: E2E de navegador, QA visual, teste humano de convite. GATES: Auth (URLs, SMTP, senha), deploy, criar organizacao Smart, catalogo comercial, decisao de comissao, worker (segredo + agendador).


## 21. Revoked-actor dispatch LIVE — 19/09/2026
- LIVE: `20260928_revoked_actor_dispatch_v1`, registrada no Supabase como `20260919194224 revoked_actor_dispatch_v1`. Não reaplicar.
- O starvation por ator revogado foi fechado: runs órfãos deixam de ocupar a lista dispatchable e o sweep service-role-only terminaliza/cancela estados elegíveis de forma governada.
- Harness LIVE rollback-only: 22/22 PASS. SECURITY DEFINER permanece 8; anon EXECUTE 0.
- Advisors pós-apply: segurança 0 WARN/0 ERROR; performance sem WARN novo, somente INFO já conhecidos.
- Zero resíduo sintético em runs, artifacts, financial_events e reconciliation.
- P0 técnico independente conhecido para o worker: nenhum. Gates atuais para piloto Smart: criar organização Smart, publicar app/origin, configurar Auth+SMTP, publicar catálogo comercial e executar teste humano pelo navegador. Segredo+agendador do worker permanecem desativados.


## 21. Deployment & tenant wave 4 - 25/09/2026
- LIVE: ate `revoked_actor_dispatch_v1` (20260919194224). Verificado: DEFINER 8 (anon 0), advisor de seguranca 0 WARN/0 ERROR, zero residuo, catalogo de referencia VAZIO, 0 catalogo de tenant, organizacao Smart NAO existe, 1 administrador de plataforma ativo. Drift: nenhum alem de `catalog_publish_v1` (NOT LIVE) e do baseline `harden_legacy_rls_foundation` sem arquivo (`docs/deployment/MIGRATION-DRIFT.md`).
- NOT LIVE (harness 40/40): `20260929_catalog_publish_v1`.
- IMPLEMENTED: catalogo administravel pelo navegador, status de configuracao, rota de referencia da plataforma, bootstrap seguro de organizacao, env fail-closed, preflight.
- OWNER: dominio, Vercel + env, Auth (URLs, SMTP, senha), dados do catalogo de referencia, criar a Smart, dados comerciais da Smart, decisao de comissao, revisar `20260929`.


## 22. Catalog publication LIVE — 19/09/2026
- LIVE: `20260929_catalog_publish_v1`, registered by Supabase as `20260919231013 catalog_publish_v1`. Do not reapply.
- Table-version and checklist publication are now governed and usable without SQL. Full harness 40/40 PASS before and after LIVE apply.
- Security remains clean: 0 WARN / 0 ERROR; SECURITY DEFINER 8; anon DEFINER execute 0; zero synthetic residue.
- Post-apply Performance Advisor exposed 2 WARNs for multiple permissive UPDATE policies created by the catalog publication design.
- PREPARED, NOT LIVE: `20260930_catalog_update_policy_merge_v1.sql`, which merges those policies without changing grants/functions/triggers/data. Merge harness 4/4 PASS; full catalog regression with merge 40/40 PASS.
- HUMAN GATE: authorize LIVE apply of 20260930 before continuing deployment closure.


## 23. Catalog policy merge LIVE — 19/09/2026
- LIVE: `20260930_catalog_update_policy_merge_v1`, registered by Supabase as `20260919231650 catalog_update_policy_merge_v1`. Do not reapply.
- Purpose: merged the duplicate permissive UPDATE policies introduced by catalog publication, without changing grants/functions/triggers/data.
- Harness against LIVE: 4/4 PASS.
- Performance Advisor: duplicate-policy WARNs removed; INFO only remains.
- Security Advisor: 0 WARN/0 ERROR; SECURITY DEFINER 8; anon DEFINER execute 0.
- Zero synthetic residue in catalog/financial reconciliation surfaces.
- Current pilot blockers are now deployment and real Smart configuration rather than an independent technical P0.


## 24. Vercel project discovered — 19/09/2026
- Connected Vercel account/team: `bossprt's projects`.
- Project exists: `corban-saas` (`prj_X63Eyy85aWFU1DvPV0XtnM0F1BG5`).
- Git integration is active: pushes on `architecture/corban-os-master-v2` are producing READY preview deployments.
- Latest observed preview: `dpl_Bgtw1VJwWCqypgyQtF1Cyg3Cbp95`, commit `01011c74...`; target is not production.
- The latest preview is protected by Vercel Authentication. No runtime logs were present for it.
- Historical runtime telemetry shows an older deployment had missing Supabase URL/key in middleware; last occurrence was on 18/09/2026.
- This connector session can inspect projects/deployments/runtime telemetry, but does not expose production env mutation or production promotion. Those remain an external Owner action.


## 25. Vercel env configured — 19/09/2026
Owner confirmed Vercel environment variables for Supabase URL, publishable/anon key, public site URL and service-role secret were configured. Worker variables remain intentionally absent. A fresh preview deployment should be generated from this branch to validate the runtime with the new configuration.


## 26. Commercial Model V3 — 19/09/2026
- Decisão de produto aprovada e documentada em `docs/CORBAN-COMMERCIAL-MODEL-V3.md`.
- O tenant deve possuir sua operação comercial; Platform Admin não deve cadastrar a operação de cada empresa.
- Fluxo-alvo: Banco → Convênio → Produto/Tabela → Tipo de Contrato → Prazo → coeficiente/taxa → comissão recebida → distribuição por grupos.
- Tipo de Contrato substitui “Modalidade” na UX e deve ser independente de Produto.
- Produto operacional = tabela comercial do tenant.
- Catálogo nacional deverá trazer 27 governos/GDF + 26 prefeituras de capitais como templates habilitáveis, sem amarrar convênio a banco.
- Bancos, provedores, convênios usados, tabelas, prazos, coeficientes, comissões, grupos e repasses são controlados pelo tenant.
- Códigos técnicos devem ser gerados automaticamente e escondidos do usuário.
- Grupos de comissão são dinâmicos e uma condição comercial deve cadastrar todos os repasses de uma vez; importação deve suportar uma coluna por grupo.
- A modelagem LIVE atual ainda usa conceitos antigos (`products` globais, `modalities.product_id`, `agreements.bank_id`); precisa de migração compatível, sem renome/destruição direta.
- Próxima onda deve começar por auditoria de impacto e migration plan. Nenhuma DDL LIVE autorizada por esta decisão.

## 27. Commercial Model V3 implementado na branch — 26/09/2026
- Migration `20261002_commercial_model_v3_foundation_v1` PREPARADA (NÃO aplicada LIVE). Harness rollback-only: ALL PASS (139 checks), sem resíduo. Unit 263/263, tsc, eslint, build verdes. Inclui política de repasse versionada (base bruta/líquida) e Origem da Produção Própria/Terceiro (doc V3 §19–§20).
- App: `/app/comercial` (bancos, provedores, convênios nacionais 27+26 e próprios, grupos de comissão dinâmicos, tabelas, condição única com todos os grupos, importação CSV/XLSX com uma coluna por grupo, publicação); simulação por condição; configuração V3.
- LIVE continua no modelo antigo até o Human Gate de aplicação. Grupos ainda não alimentam snapshot/split/repasse.


## 27. Commercial Model V3 LIVE — 20/09/2026
- Owner authorized and migration `commercial_model_v3_foundation_v1` was applied LIVE, registered by Supabase as `20260920133017`. Do not reapply.
- Live harness after apply: 139/139 PASS rollback-only.
- V3 is now present in production: independent contract types, national agreement templates, tenant-owned banks/providers/agreements/groups, payout policies, V3 routes and commercial conditions.
- Seeds: 4 contract types; 53 national templates (27 governments/GDF + 26 capital city halls).
- RLS enabled on all 12 new V3 tables; Security Advisor has no WARN/ERROR.
- SECURITY DEFINER application inventory remains unchanged at 8 total (6 private + 2 public).
- No synthetic tenant/commercial V3 data persisted.
- Performance Advisor reports INFO only, including 11 unindexed FK candidates on new V3 tables; review after real workloads, not a blocker.
- Remaining roadmap: Smart real configuration, CEP autofill, adaptive Gemini-first import agent + metering, operational monitoring agent, payout/proposal snapshot integration and atomic bulk import.

## 28. Next wave V3 preparada na branch — 20/09/2026
- CEP automatico e guia do `/app/comercial` ja no app (sem DDL). Tres migrations PREPARADAS e NAO aplicadas: importacao atomica (20261004), fundacao IA + metering (20261005), Action Center (20261006); harnesses rollback-only ALL PASS. Unit 302/302, tsc, eslint, build verdes.
- LIVE continua so com o Commercial Model V3 (20260920133017). Nenhuma chave Gemini, nenhum gasto, nenhuma mudanca financeira.
- Auditoria: `docs/audits/AUDIT-2026-09-20-NEXT-WAVE-V3.md`; onda F (payout/snapshot/ledger) apenas desenhada.


## 28. Next Wave V3 LIVE — 20/09/2026
- LIVE migrations: `commercial_bulk_import_v1` = 20260920173825; `ai_import_metering_v1` = 20260920173830; `action_center_v1` = 20260920173835. Do not reapply.
- Atomic commercial bulk import is live.
- AI import mapping memory + metering/credits foundation are live, but AI remains OFF until configured; no Gemini secret has been registered and no paid call has been made.
- Action Center persistence/governance is live.
- Post-apply rollback harnesses: 22/22 bulk, 62/62 AI/metering, 54/54 Action Center.
- RLS enabled on all newly checked AI/Action Center tables; SECURITY DEFINER inventory unchanged at 8 app functions.
- Security Advisor has no WARN/ERROR; only known INFO for closed platform-admin tables.
- Zero synthetic AI/attention data persisted after verification.
- Remaining gates: Gemini secret, first paid call, credit tariff/monthly limits, and all Wave F financial/payout DDL.


## Regra permanente de continuidade entre chats

Decisão do Owner: toda decisão relevante de produto, arquitetura, segurança, operação, Human Gate, migration LIVE e próximo passo deve ser registrada nos arquivos do projeto antes de depender do histórico do chat.

Objetivo: qualquer novo chat/IA deve conseguir retomar o Corban OS lendo o repositório, sem exigir que o Owner reconte o contexto.

Prática obrigatória:
- requisitos de produto -> documentação funcional/ADR correspondente;
- estado executável/LIVE -> `CORBAN-CURRENT-STATE.md`;
- próxima execução -> `.ai/CURRENT-TASK.md`;
- mudanças arquiteturais/invariantes -> ADR;
- migrations LIVE devem registrar versão real do Supabase e "DO NOT REAPPLY";
- nunca considerar uma decisão importante "salva" apenas porque apareceu no chat.


## 29. UX Comercial reorganizada — 20/09/2026
Implementado diretamente pelo ChatGPT na branch `architecture/corban-os-master-v2`, sem Claude e sem DDL:
- Comercial principal usa cards/resumos para cadastros-base em vez de listas crescentes.
- Novos gerenciadores dedicados:
  - `/app/comercial/instituicoes`
  - `/app/comercial/origens`
  - `/app/comercial/convenios`
  - `/app/comercial/grupos`
- Gerenciadores têm cadastro, edição de nome e inativação/reativação.
- Instituição/Origem fica separada visualmente de empresas de origem de terceiros.
- Grupo de comissão: usuário informa nome + como o percentual é lido; classificação técnica `kind` não é mais decisão obrigatória de UX.
- Política de repasse foi simplificada na UI para “Regra padrão de comissão (opcional)”.
- Importação em massa CSV/XLSX foi promovida como caminho principal das condições de tabela; cadastro manual permanece disponível.
- Nenhum registro real foi reclassificado/apagado automaticamente.
- Hope cadastrada incorretamente como provider permanece inativa até autorização explícita para exclusão.


## Commercial UX consolidation — tables manager
- `/app/comercial` is now a compact dashboard instead of a long CRUD/list page.
- Product/Tables/Conditions moved to dedicated `/app/comercial/tabelas`.
- The table manager shows conditions in a compact grid and makes **Importar planilha** the primary path; manual condition entry is secondary/collapsible.
- CSV/XLSX bulk import remains atomic and uses the LIVE `import_commercial_conditions` RPC.
- No new DDL and no Claude usage.


## Empresa de origem — classificação editável
Decisão do Owner: a classificação de uma empresa de origem de terceiros não é definitiva no cadastro.

Exemplo:
- cadastrar inicialmente como Correspondente;
- depois corrigir para Promotora.

Regra de UX:
- o gerenciador de empresas de origem deve permitir editar **nome + classificação**;
- classificações atuais: Banco direto, Master, Promotora, Correspondente, Parceiro, Outro;
- editar a classificação não muda automaticamente a direção da relação comercial nem a origem da produção das tabelas;
- alterações históricas sensíveis devem continuar auditáveis quando houver vínculo financeiro/contratual.


## Grupo de vendedor como perfil comercial herdável
Correção conceitual do Owner a partir da operação real e do material 2Tech:

- **Grupo de vendedor** não é uma classificação de qualidade como Bronze/Prata/Ouro por padrão.
- No Corban OS, ele deve representar o **perfil comercial do vendedor/canal**, por exemplo:
  - Corretor;
  - Parceiro;
  - Afiliado;
  - Indicador;
  - outros grupos criados pelo tenant.
- No cadastro do vendedor deve existir um campo explícito para selecionar o grupo comercial ao qual ele pertence.
- Ao selecionar o grupo, o vendedor **herda automaticamente a regra de comissão configurada para aquele grupo**.
- A comissão padrão vem do grupo; exceções específicas podem existir, mas devem ser explícitas e auditáveis.
- O sistema não deve exigir que o usuário escolha novamente a mesma classificação em vários lugares.

Modelo funcional:
`Vendedor -> Grupo de Vendedor -> Regra de Comissão do Grupo -> Comissão efetiva conforme a tabela/condição`

Exemplo:
- Grupo: Corretor
- Regra do grupo: 65% da comissão recebida
- Vendedor João pertence ao grupo Corretor
- João herda automaticamente os 65%, salvo override explícito permitido pela política.

Distinção:
- Grupo de vendedor = perfil/canal comercial do vendedor;
- Regra de comissão = como esse grupo é remunerado;
- classificação adicional de performance (Bronze/Prata/Ouro etc.) pode existir futuramente como outra dimensão, mas não deve ser confundida com o grupo comercial principal.


## Vendedor — grupo comercial, grupo de comissão e categoria PF/PJ/SUB
Correção conceitual do Owner a partir das telas reais da 2Tech.

### 1. Grupo de Vendedores
É um cadastro livre do tenant. O tenant pode criar quantos grupos quiser; o exemplo da 2Tech mostra apenas "BÁSICO", mas isso não limita o conceito.

Exemplos possíveis no Corban OS:
- Corretor;
- Parceiro;
- Afiliado;
- Indicador;
- Time interno;
- qualquer outro grupo criado pela empresa.

No cadastro do vendedor existe um campo explícito **Grupo de Vendedor** que aponta para esse cadastro.

### 2. Grupo de Comissão
É outro vínculo, separado do Grupo de Vendedor.

No cadastro do vendedor também deve existir **Grupo de Comissão**.
Esse vínculo determina qual regra de comissão o vendedor herda quando a produção/condição correspondente é calculada.

Portanto:
`Vendedor -> Grupo de Vendedor`
e
`Vendedor -> Grupo de Comissão`
são relações distintas.

Não colapsar uma na outra.

### 3. Categoria PF / PJ / SUB
O cadastro do vendedor possui uma categoria operacional/comercial:
- PF;
- PJ;
- SUB;
- outros tipos futuros se necessário.

A categoria **SUB** tem impacto financeiro e não é mero rótulo.

Regra de negócio descrita pelo Owner:
- SUB 100%: quando a produção vem do banco/master, a comissão esperada para a empresa pode vir zerada, pois 100% do resultado pertence ao sub;
- SUB 90%: a produção deve registrar que a empresa espera reter 10% do total econômico daquela produção;
- de forma geral, o percentual do SUB determina a parcela do resultado destinada ao sub e, por diferença, a parcela esperada para a empresa.

Exemplo conceitual:
`base econômica 100% -> SUB 90% -> empresa espera 10%`.

Essa regra deve ser modelada separadamente da comissão de vendedor e da comissão recebida do banco, para não confundir:
- receita recebida da instituição;
- participação do SUB;
- comissão do vendedor/grupo;
- receita líquida/esperada da empresa.

### 4. Outras regras do cadastro
As telas da 2Tech mostram diversas flags e parâmetros no cadastro do vendedor, como:
- bloqueio de comissão no fechamento;
- comissão diferida;
- comissão bônus;
- permissão para cadastrar contrato;
- visualização de comissão de repasse;
- liberação sem físico;
- chamados;
- contrato com físico ausente;
- termo assinado;
- relatório de refinanciamento;
- custo de portabilidade;
- quantidade de dias para pendências/bloqueios/estornos;
- desconto de IR;
- valor mínimo para fechamento;
- desconto TED;
- dados Assertiva;
- observação.

Decisão: esses campos **não devem ser copiados automaticamente** para o Corban OS. Eles servem como evidência de que o vendedor pode ter políticas, permissões, SLAs e parâmetros financeiros/operacionais próprios. Cada regra deve ser avaliada antes de entrar no produto, agrupando por domínio em vez de criar uma tela monolítica.

### Direção de produto
O cadastro do vendedor deve ser modular, provavelmente por abas/seções:
- Dados básicos;
- Dados bancários;
- Vínculos comerciais;
- Comissão;
- Permissões;
- Regras operacionais;
- Contatos/documentos.

Evitar uma tela única com dezenas de toggles sem contexto.


## Fatores diários e fatores fixos por instituição
Requisito do Owner a partir da operação real e da tela 2Tech "Importar Fator Diário".

### Objetivo
O Corban OS precisa suportar bancos/instituições que trabalham com **fatores diários** e também instituições/produtos que usam **fatores fixos** até nova alteração.

Isso é necessário tanto para o módulo comercial quanto para o CRM, porque simulação, qualificação e oferta ao cliente dependem do fator vigente correto.

### Modelo funcional
Cada instituição/produto/convênio deve poder definir seu regime de fator:

1. **Fator diário**
   - usado por instituições como Daycoval;
   - pode variar por data/período, convênio, produto/tabela e tipo de contrato;
   - deve permitir importação em lote;
   - formatos prioritários: PDF e Excel/XLSX; CSV também pode ser aceito;
   - o sistema deve interpretar o arquivo, mostrar prévia, detectar alterações e só então publicar/ativar a nova versão;
   - histórico nunca deve ser apagado: nova carga gera versão/vigência nova;
   - deve ser possível consultar qual fator estava vigente em uma data passada.

2. **Fator fixo**
   - cadastro manual;
   - permanece vigente até uma alteração futura;
   - alteração cria nova vigência/versão em vez de sobrescrever o histórico;
   - pode ser definido por instituição + convênio + produto/tabela + tipo de contrato + prazo, conforme aplicável.

### Importação de fator diário
Fluxo desejado:
`Instituição -> Convênio -> Produto/Tabela (opcional conforme banco) -> Tipo de Contrato -> Período/data -> Arquivo -> Prévia -> Validar -> Publicar`

A tela deve permitir:
- selecionar instituição;
- selecionar convênio;
- opcionalmente limitar a produto/tabela;
- selecionar um ou mais tipos de contrato;
- informar data/período de vigência;
- enviar PDF/XLSX/CSV;
- visualizar fatores detectados;
- comparar com a versão atual;
- sinalizar linhas novas, alteradas, removidas/ausentes e conflitos;
- confirmar antes de tornar os fatores vigentes.

### PDF/Excel
A extração pode usar o mesmo princípio do importador comercial adaptativo:
- parser determinístico para estrutura/números;
- IA somente para mapear layout/semântica quando necessário;
- nenhum fator financeiro pode ser inventado;
- baixa confiança exige revisão humana;
- preservar arquivo original, fingerprint, mapeamento e linhagem.

### Integração com CRM
O CRM deve consultar automaticamente o fator vigente aplicável ao lead/cliente/proposta no momento da simulação.
A interface não deve exigir que o operador procure manualmente a planilha do banco quando houver fator válido no sistema.

### Relação com Tabelas/Condições
Fator é um domínio próprio, mas se relaciona com:
- Instituição;
- Convênio;
- Produto/Tabela;
- Tipo de Contrato;
- Prazo;
- Vigência.

Não confundir fator diário com:
- comissão recebida;
- regra de comissão;
- taxa nominal;
- coeficiente, embora possam coexistir na mesma condição comercial.

### UX
Criar no futuro uma área dedicada, provavelmente em:
`Cadastros/Comercial -> Fatores`
ou
`Operacional -> Importações -> Fatores`

Com duas ações claras:
- **Importar fatores diários**
- **Cadastrar fator fixo**

### Segurança e histórico
- nunca sobrescrever silenciosamente histórico;
- publicação deve ser versionada e auditável;
- importação deve ter prévia;
- alterações em massa devem ser atômicas;
- arquivo de origem deve permanecer vinculado à versão publicada.


## Tipo de Contrato como cadastro gerenciado em Produtos
Clarificação do Owner a partir da tela real da 2Tech.

Na arquitetura funcional de referência, **Tipo de Contrato** fica dentro do domínio de **Produtos** e possui gerenciamento próprio.

Exemplos mostrados:
- Antecipação de benefício;
- Ativação;
- Cartão C/ Saque;
- Cartão S/ Saque;
- Compra de Dívida;
- Conta Simples;
- Contrato Novo;
- Novo - Aumento Salarial;
- Portabilidade;
- Refin + Margem;
- e outros.

O cadastro não é apenas um nome. O tipo de contrato pode carregar flags funcionais como:
- habilitar na esteira de solicitação/digitação;
- habilitar para cadastro/busca de comissão;
- status ativo/inativo.

### Decisão para Corban OS
- **Tipo de Contrato** deve continuar sendo um catálogo reutilizável e independente de uma tabela específica.
- Porém, não deve ser tratado como lista fixa e invisível para sempre.
- Deve existir uma área de gerenciamento dentro de **Cadastros/Produtos**, onde perfis autorizados possam visualizar, habilitar/inativar e, conforme governança definida, criar/editar tipos.
- O tipo de contrato pode possuir capacidades/flags operacionais que controlam onde ele aparece no sistema.
- Não duplicar Tipo de Contrato em cada Produto/Tabela.
- Produto/Tabela referencia um Tipo de Contrato já cadastrado ao definir suas condições.

### UX sugerida
`Cadastros -> Produtos -> Tipos de Contrato`

Tela com:
- pesquisa;
- paginação;
- nome;
- uso na esteira;
- uso em comissão;
- status;
- visualizar/editar.

Essa decisão substitui a visão anterior de que bastaria manter somente quatro tipos comuns fixos e sem gerenciamento visível.


## Sincronização entre correspondentes / upstream-downstream
Requisito do Owner inspirado no funcionamento interno da 2Tech entre empresas que usam a mesma plataforma.

### Cenário real
Exemplo:
- Smart Promotora usa 2Tech;
- Hope usa 2Tech;
- Efetiva Mais usa 2Tech.

Como todas operam dentro da mesma plataforma, a 2Tech consegue associar cada empresa por identificador/chave interna e sincronizar dados entre a empresa que origina/repassa a produção e a empresa que recebe.

Exemplo de relação:
`Efetiva Mais -> repassa produção para Smart Promotora`

Quando a Efetiva atualiza a esteira/contrato, a Smart recebe a atualização correspondente sem trabalho manual.

### Escopo prioritário: esteira
A sincronização de esteira é considerada pelo Owner o caso mais simples e prioritário.

Modelo desejado:
- cada organização mantém sua própria visão/tenant;
- uma relação comercial upstream/downstream é cadastrada explicitamente;
- contratos/propostas compartilhados recebem um identificador de correlação entre as duas organizações;
- alterações de status relevantes no upstream propagam eventos para o downstream;
- o downstream vê a atualização em sua própria esteira;
- preservar origem, timestamps, evidência e histórico de cada atualização;
- não permitir que uma organização veja dados de outra fora das relações explicitamente autorizadas.

Possível fluxo:
`Upstream contract event -> correlation/external id -> integration event -> downstream proposal mirror/update -> audit trail`

### Tabelas de comissão vindas do upstream
Quando a empresa upstream repassa uma tabela comercial, o downstream deve receber apenas a **condição econômica que o upstream paga/repassa**.

Exemplo:
Efetiva Mais disponibiliza para Smart:
- contrato/tabela elegível;
- prazo/tipo;
- comissão que Efetiva paga à Smart;
- vigência e demais condições recebidas.

Isso **não deve sobrescrever nem transportar automaticamente**:
- grupos de comissão internos da Smart;
- regras de vendedor da Smart;
- percentuais pagos pela Smart a corretores/parceiros;
- política de repasse interna da Smart.

Portanto existem duas camadas:
1. **Condição upstream recebida** = quanto o fornecedor/master/correspondente paga para a Smart.
2. **Distribuição interna Smart** = quanto a Smart paga para seus grupos/vendedores, calculado localmente.

### Arquitetura conceitual
Separar:
- `ExternalOrganizationLink` / vínculo entre organizações;
- `ExternalContractReference` / correlação de proposta/contrato;
- `UpstreamCommercialOffer` / condição/tabela recebida;
- `LocalPayoutPolicy` / regras internas do tenant.

A condição upstream pode alimentar o cálculo da receita esperada da Smart, mas nunca deve ser confundida com a política interna de comissão.

### Quando as empresas não usam a mesma plataforma
O mesmo conceito deve funcionar por integração externa:
- API;
- webhook;
- importação;
- arquivo;
- conector específico.

A sincronização interna tenant-to-tenant é apenas o caso mais eficiente, não uma dependência estrutural.

### Regra de segurança
- vínculo sempre explícito e tenant-scoped;
- IDs externos não autorizam acesso por si só;
- mínimo compartilhamento necessário;
- eventos idempotentes;
- sem update destrutivo silencioso;
- divergências devem gerar caso de reconciliação/atenção.

### Prioridade
1. sincronização de esteira/status de contratos;
2. sincronização de condições/tabelas upstream;
3. apenas depois estudar automação mais profunda de comissionamento entre empresas.


## Importação de Produto/Tabela — componentes de comissão e repasses nomeados
Requisito refinado pelo Owner após análise da tela 2Tech e do arquivo real RelatorioProdutos.xls.

### Estrutura observada no arquivo real
O modelo possui, além dos dados do produto/tabela:
- Banco;
- Convênio;
- Tabela/Nome do Produto;
- Código no Banco;
- Vigência;
- Prazo inicial/final;
- Tipo de Contrato;
- Tipo de Formalização;
- Fator;
- Taxa a.m.;
- faixas de idade/valor/taxa.

A remuneração da **empresa** aparece decomposta em vários componentes:
- À Vista (Empresa);
- Bônus (Empresa);
- Diferido (Empresa);
- Bônus 2 % (Empresa);
- Bônus 3 % (Empresa);
- Plástico (Empresa);
- Seguro fixo (Empresa).

Depois existem até **5 conjuntos de repasse**, cada um repetindo os mesmos componentes:
- À Vista (Repasse N);
- Bônus (Repasse N);
- Diferido (Repasse N);
- Bônus 2 % (Repasse N);
- Bônus 3 % (Repasse N);
- Plástico (Repasse N);
- Seguro fixo (Repasse N).

O arquivo suporta valores percentuais e valores monetários, evidenciado por células com formato/símbolo de R$ em componentes como plástico/seguro.

### Problema de UX identificado
Rótulos genéricos como **Repasse 1, Repasse 2, Repasse 3...** são perigosos para o tenant.
Se a organização já possui os grupos de comissão configurados, uma coluna ordinal pode causar erro humano, por exemplo:
- comissão destinada a Corretor ser importada como Parceiro;
- Parceiro ser confundido com Indicador.

### Decisão para Corban OS
A exportação/modelo de importação deve ser **gerada dinamicamente a partir da configuração do tenant**.

Exemplo: se os grupos ativos forem:
- Corretor;
- Parceiro;
- Indicador;

o modelo deve gerar colunas semanticamente nomeadas, por exemplo:
- À Vista (Corretor);
- Bônus (Corretor);
- Diferido (Corretor);
- Plástico (Corretor);
- Seguro fixo (Corretor);
- À Vista (Parceiro);
- Bônus (Parceiro);
- ...;
- À Vista (Indicador);
- ...

Não usar "Repasse 1/2/3" como nomenclatura principal quando o sistema já conhece o grupo correspondente.

### Modelo financeiro
Separar explicitamente:
1. **Componentes recebidos pela empresa**
   - à vista;
   - diferido;
   - bônus 1/2/3;
   - plástico;
   - seguro fixo;
   - futuros componentes configuráveis.

2. **Componentes de repasse por grupo**
   - cada grupo pode receber valores diferentes por componente;
   - o repasse representa quanto a empresa paga àquele grupo/canal;
   - grupo de vendedor e grupo de comissão continuam vínculos distintos no cadastro do vendedor.

### Tipo do componente
Cada componente deve suportar sua unidade:
- percentual (%);
- valor fixo (R$).

Não inferir somente pelo nome.
No importador, a unidade deve ser validada explicitamente ou inferida apenas quando o arquivo traz evidência inequívoca (ex.: símbolo R$), sempre com prévia.

### Importador adaptativo
O Corban OS não deve depender de posição fixa de coluna.
Fluxo:
`arquivo -> leitura estrutural -> identificação semântica -> mapeamento para componentes/grupos -> prévia -> validação -> importação atômica`

O mapeamento deve:
- reconhecer nomes dos grupos do tenant;
- preservar colunas desconhecidas;
- detectar troca/ambiguidade entre grupos;
- impedir publicação se houver risco de mapear comissão para o grupo errado;
- permitir modelo Excel gerado pelo próprio Corban OS já com os nomes reais dos grupos.

### Regra importante
A tabela recebida de um upstream pode trazer **quanto o upstream paga para a empresa**, mas as colunas de repasse interno são responsabilidade do tenant.
Nunca transportar automaticamente regras internas de comissão de outra organização para o tenant downstream.


## Meta principal — importação inteligente com cálculo automático de repasses

Decisão central do Owner para o Corban OS:

O sistema deve eliminar o trabalho manual de passar horas atualizando tabelas e comissões.

### Cenário alvo
O usuário recebe uma planilha de um banco/master/origem, por exemplo HOPE, contendo:
- banco;
- convênio;
- produto/tabela;
- tipo de contrato;
- prazos;
- base de cálculo;
- comissão à vista;
- bônus;
- diferido;
- vigência;
- taxa;
- tipo de fator/fator;
- e outros componentes conforme o produto.

O usuário importa o arquivo e informa as regras locais da empresa, por exemplo:
- imposto: 6%;
- Corretores: 65%;
- Parceiro: 80%;
- Balcão: 50%.

A partir daí o Corban OS deve:
1. interpretar o arquivo;
2. cadastrar/atualizar automaticamente tabelas, prazos, vigências, taxas, fatores e componentes recebidos;
3. identificar quais componentes existem de fato no arquivo;
4. aplicar as regras locais já cadastradas para os grupos;
5. perguntar ao usuário apenas o que realmente for necessário quando surgir um componente novo ou opcional.

### Perguntas condicionais
Se o arquivo tiver **Diferido > 0**, perguntar algo como:
- "Deseja repassar comissão diferida?"
- se sim, para quais grupos e em qual percentual/regra?

Se houver **Plástico**, perguntar:
- se esse componente entra no repasse;
- para quais grupos;
- se o repasse é em % ou R$, conforme o componente.

Mesma lógica para:
- Bônus;
- Bônus 2;
- Bônus 3;
- Seguro fixo;
- outros componentes futuros.

Se o componente não existir no arquivo, não perguntar sobre ele.

### Regras por convênio
As políticas não são necessariamente universais.
O sistema deve aceitar regras em camadas:
1. padrão da organização;
2. override por banco/instituição;
3. override por convênio;
4. override por produto/tabela;
5. exceção explícita por condição, se necessário.

A regra mais específica prevalece, sempre com rastreabilidade.

Exemplo:
- padrão Smart: imposto 6%, Corretor 65%, Parceiro 80%, Balcão 50%;
- Governo do Acre pode ter regra diferente;
- outro convênio pode não repassar Diferido;
- produto cartão pode ter regra específica para Plástico/Seguro.

### Princípio de UX
O usuário não deve preencher centenas de células manualmente.

Fluxo desejado:
`Upload -> leitura automática -> reconhecimento de componentes -> aplicação das regras conhecidas -> perguntas somente sobre ambiguidades/novos componentes -> prévia completa -> confirmar -> importação atômica`

### Exemplo com arquivo HOPE analisado em 20/09/2026
O arquivo `RelatorioMelhorComissao.xls` possui:
- Banco: HOPE;
- Convênio: Gov. AC;
- Produto;
- Tipo de Contrato;
- Prazo Inicial/Final;
- Base Cálculo À Vista/Bônus/Diferido;
- À Vista;
- Bônus;
- Diferido;
- Ativação Imediata;
- vigência;
- TAXA a.m.;
- Tipo Fator;
- Fator.

No arquivo analisado, os valores de **Bônus** e **Diferido** estão zerados em todas as linhas, portanto o sistema não deveria perguntar sobre repasse desses componentes nessa importação.

O arquivo traz `Tipo Fator = DIÁRIO`, o que também deve alimentar a configuração de fator aplicável sem exigir recadastro manual.

### Motor de cálculo
Separar:
- componente recebido do upstream;
- base bruta/líquida;
- imposto/desconto;
- regra de repasse do grupo;
- componente repassado;
- receita esperada da empresa.

Exemplo simplificado:
`comissão recebida -> base após imposto -> regra do grupo -> repasse -> retenção/receita esperada`

Todos os cálculos financeiros devem ser determinísticos, versionados e auditáveis. IA pode mapear a planilha, mas não deve inventar percentuais nem executar cálculo financeiro fora das regras determinísticas.

### Objetivo final
O Corban OS deve transformar atualização de tabela/comissão de uma tarefa manual de horas em um fluxo de poucos minutos, com revisão humana apenas onde houver novidade, ambiguidade ou regra ainda não cadastrada.


## Estrutura macro do ecossistema Corban
Correção do Owner:

A estrutura conceitual final deve ser entendida como:

```text
CORBAN
├── SmartMatch
└── DeskcommCRM
```

### CORBAN
É a camada/ecossistema principal, o sistema operacional do correspondente bancário.

### SmartMatch
É um módulo/produto dentro do ecossistema Corban, voltado para aquisição, atendimento, qualificação, recuperação e medição de receita/leads.

### DeskcommCRM
Também faz parte da estrutura maior do Corban como frente/módulo de CRM e comunicação/operação comercial, ainda que possa continuar existindo tecnicamente como projeto/repositório separado durante o desenvolvimento.

### Regra arquitetural
- Corban é o guarda-chuva principal.
- SmartMatch e DeskcommCRM não devem ser tratados como projetos totalmente desconectados do ponto de vista de produto.
- Integrações entre eles devem ser feitas por contratos claros (APIs/eventos/identidades), sem acoplamento inseguro de banco ou secrets.
- Cada componente pode manter infraestrutura/repositório independente enquanto a arquitetura de produto converge sob Corban.


## Reestruturação de navegação por domínio — 20/09/2026
Implementação V1, reversível e sem DDL:
- menu principal passa a representar áreas de negócio: Visão geral, CRM, Operacional, Financeiro, Cadastros, Relatórios e Configuração;
- novos hubs `/app/crm`, `/app/operacional`, `/app/cadastros`, `/app/relatorios`;
- módulos antigos não são removidos; ficam acessíveis pelos hubs;
- autorização continua nas páginas/actions/RLS; esconder/exibir link é somente UX;
- objetivo: abandonar navegação "robótica" por entidades técnicas e aproximar o fluxo do trabalho real.


## Auditoria estrutural para próximas ondas — 20/09/2026
Consulta somente ao schema LIVE confirmou que parte importante do modelo já existe e deve ser reaproveitada:
- rede comercial e relações upstream/downstream;
- regras de split versionadas;
- componentes de comissão com %/R$;
- grupos de comissão e condições comerciais.
Lacunas principais: perfil/cadastro de vendedor com vínculos comerciais, categoria PF/PJ/SUB e domínio versionado de fatores diários/fixos. Nenhuma DDL aplicada nesta auditoria.


## Seller/SUB e Fatores — preparados, não LIVE
As migrations `20261007_seller_commercial_profile_v1` e `20261008_commercial_factors_v1` estão na branch e passaram em harness rollback-only contra o schema LIVE.

Nenhuma das duas está aplicada em produção.

Seller/Sub adicionará: seller_groups, commercial_sellers, seller_sub_rule_versions, publicação/resolução governadas.

Fatores adicionará: commercial_factor_profiles, commercial_factor_batches, commercial_factor_entries, publicação e resolução determinísticas.

Build Vercel atual: READY. Próximo passo bloqueado apenas pelo Human Gate de DDL LIVE.


## Seller/SUB e Fatores — LIVE
Aplicadas em produção com autorização explícita do Owner:
- `20260920235725 seller_commercial_profile_v1`
- `20260920235731 commercial_factors_v1`

Validação pós-apply:
- contratos SQL de Seller/SUB e Fatores passaram;
- RLS presente nas seis novas tabelas;
- advisor de segurança: nenhum WARN/ERROR novo; somente 2 INFO já conhecidos nas tabelas exclusivas de Platform Admin;
- advisor de performance: INFO de FKs sem índice e índices ainda não usados; não foi aplicado novo DDL fora do gate autorizado.

UI adicionada:
- `/app/cadastros/vendedores`: Grupo de Vendedor, Grupo de Comissão, PF/PJ/SUB e regra SUB versionada;
- `/app/comercial/fatores`: perfis daily/fixed, cadastro manual e importação inicial CSV/XLSX;
- Central de Cadastros atualizada com Vendedores e Fatores.

Limitação atual de importação de fatores: PDF e XLS legado ainda não entram nesta primeira UI; o domínio e a linhagem já estão preparados para a próxima onda adaptativa.


## Próxima onda preparada — Componentes/Tipos de Contrato
Ainda NÃO LIVE:
- `20261009_component_commissions_v1`
- `20261010_tenant_contract_types_v1`
- `20261011_post_seller_factors_fk_indexes_v1`

As três passaram em rollback-only contra o schema LIVE.

A 20261009 cria a fundação para a meta principal do importador: componentes de comissão recebida e repasse por grupo, com valores em percentual ou R$, política por escopo e versões imutáveis.

A 20261010 transforma Tipo de Contrato em catálogo global + extensões/configurações do tenant, mantendo independência de Produto/Tabela.

A 20261011 fecha índices de FKs introduzidas por Seller/SUB/Fatores.

Nenhuma dessas migrations foi aplicada ainda.


## Componentes/Tipos de Contrato — LIVE
Aplicadas em produção com autorização explícita do Owner:
- `component_commissions_v1`
- `tenant_contract_types_v1`
- `post_seller_factors_fk_indexes_v1`

Incluído no catálogo global:
- Novo
- Refinanciamento
- Compra de Dívida
- Portabilidade
- **Refin/Portabilidade** — usado para refinanciamento de contrato oriundo de portabilidade.

Validação pós-apply:
- três contratos SQL passaram;
- security advisor sem WARN/ERROR novo, apenas os 2 INFO históricos de Platform Admin;
- Refin/Portabilidade confirmado no catálogo LIVE;
- índices de FK de Seller/SUB/Fatores aplicados.

Aplicação em andamento sem Claude:
- gerenciamento de Tipos de Contrato por tenant;
- flags Habilitado / Usar na esteira / Usar em comissão;
- regras de comissão por componentes e por Grupo de Comissão.


## Smart Commercial Import V1 — preparado, não LIVE
A fundação da meta principal está preparada:
- parser determinístico para XLSX/CSV;
- modelo XLSX dinâmico com nomes reais dos grupos;
- migration `20261012_smart_commercial_import_v1` validada em rollback-only;
- RPC atômica preparada para cadastrar/atualizar catálogo, condições, componentes e fatores em uma transação.

Proteções:
- Repasse 1/2/3 não é mapeado automaticamente;
- Plástico ambíguo exige unidade;
- Tipo de Contrato deve existir e estar habilitado;
- política interna é escolhida explicitamente;
- tabela fica em rascunho para revisão;
- IA não calcula nem inventa valores.

Nenhum objeto de 20261012 está LIVE ainda.


## Smart Commercial Import V1 — LIVE
Aplicada em produção com autorização explícita do Owner:
- `20260921003829 smart_commercial_import_v1`

Validação pós-apply:
- contrato SQL passou;
- security advisor sem WARN/ERROR novo;
- permanecem apenas os 2 INFO históricos de Platform Admin.

Aplicação adicionada:
- `/app/comercial/importacao-inteligente`;
- prévia sem gravar;
- parser determinístico CSV/XLSX;
- perguntas condicionais para Diferido/Plástico/Bônus;
- escolha explícita de produção Própria/Terceiro;
- escolha explícita de regra interna versionada;
- confirmação obrigatória quando o arquivo legado usa Repasse 1/2/3;
- aplicação por RPC atômica;
- Tabelas permanecem em rascunho para revisão antes da publicação.

Limitação consciente:
- XLS legado e PDF ainda não são suportados por esta primeira UI. A próxima etapa deve tratar esses formatos sem degradar as regras de segurança e prévia.


## Build estável pós Smart Import UI
Estado confirmado:
- produção Vercel voltou a `READY` no commit `a0bad4a481feed5c0499ec566bfe9401d49c7e1d`;
- Smart Import guiado CSV/XLSX permanece ativo;
- tentativa experimental de cálculo econômico detalhado na prévia foi revertida porque introduziu erro de compilação; não afetou o banco nem a versão estável;
- nenhuma migration foi revertida;
- `smart_commercial_import_v1` continua LIVE e validada.

Próxima necessidade real de ambiente local:
- suporte a XLS legado e PDF;
- geração correta de lockfile ao adicionar bibliotecas;
- testes locais com arquivos reais HOPE/2Tech;
- build/lint/test completos antes de novo push.

Isso justifica acionar Claude Code local em tarefa longa única, preservando quota.

## 29. Smart Import aceita XLS legado e PDF textual — 20/09/2026 (branch `feature/smart-import-xls-pdf`, nao mesclada)
- CSV, XLSX, XLS (BIFF) e PDF com texto entram pelo mesmo parser; PDF ambiguo/imagem e recusado com "necessita revisao". Regras: `docs/SMART-COMMERCIAL-IMPORT-V1.md`. Unit 329/329, tsc, eslint, build verdes. Nenhuma migration, nenhum secret.


## XLS/PDF integrado e revisão independente concluída
- PR #1 `feature/smart-import-xls-pdf` revisado e mesclado em `architecture/corban-os-master-v2`.
- Merge commit: `3915d1a454f8c994cd80dd5742f38707238fbb68`.
- Vercel do merge ficou READY.
- Auditoria adicional de visibilidade de comissão corrigiu a página `/app/comercial` para obedecer `canViewCommission`, preservando a decisão central fail-closed.
- Commit atual validado pelo Vercel: `fbca952839551254dc0990a8b969e476934ed191` — READY.
- CSV/XLSX/XLS legado/PDF textual seguem no mesmo parser comercial.
- PDF ambíguo, escaneado ou sem tabela é recusado; não há OCR nem inferência financeira.
- Nenhum DDL adicional foi necessário e nenhuma migration foi reaplicada.


## XLSX percentual — fail-closed
Após a integração XLS/PDF, foi corrigida mais uma ambiguidade financeira:
- células numéricas de XLSX formatadas como percentual agora são recusadas no Smart Import;
- motivo: o arquivo pode armazenar `0.15` e exibir `15%`, e o sistema não pode adivinhar a intenção financeira;
- o operador recebe mensagem explícita para corrigir o valor/unidade;
- teste unitário específico adicionado;
- Vercel de produção READY no commit `8277790fe548ed1532ac5a56b6a3fe9ebb6f3da8`.


## Smart Import — prévia econômica + mapeamento manual
Continuação autônoma concluída sem Claude e sem DDL:
- prévia econômica determinística por Grupo de Comissão;
- cálculo usa somente inteiros escalados/BigInt, nunca float;
- ordem da prévia: comissão recebida → imposto/desconto → repasse do grupo → retenção da empresa;
- cada grupo é cenário alternativo, nunca soma de todos os grupos;
- unidade %/R$ é preservada; unidades incompatíveis não geram retenção inventada;
- escolha da regra ocorre antes da análise para que a prévia já mostre o efeito financeiro;
- mapeamento manual fail-closed para cabeçalhos não reconhecidos de Banco, Convênio, Tabela, Tipo, Prazo, Taxa, Coeficiente e Fator;
- o arquivo é reanalisado após o mapeamento e nada é gravado antes da nova validação;
- o mesmo mapeamento da prévia é reenviado na aplicação, evitando divergência preview/apply;
- reutilizar a mesma coluna para dois campos é recusado;
- Vercel READY no commit `673bc577189c1f05834305382f2a82fd841452c5`.


## Human Gate — Smart Import policy scope guard
Nova proteção preparada após revisão adversarial:
- app já recusa política de comissão selecionada fora do escopo de Instituição/Convênio/Tabela;
- precheck LIVE encontrou **0** vínculos existentes fora de escopo;
- migration `20261013_smart_import_policy_scope_guard_v1.sql` preparada;
- contract `tests/security/smart-import-policy-scope-contract.sql` preparado;
- migration + contract passaram juntos em transação `BEGIN ... ROLLBACK`, sem persistência;
- Vercel do HEAD `113ecd2aba2cc6fbe362dc2a9ed83e8c613cb23c` está READY.

A migration substitui somente a função de guarda já existente e adiciona defesa no banco:
- policy.org_bank_id deve corresponder à rota da condição;
- policy.org_agreement_id deve corresponder à rota;
- policy.product_table_id deve corresponder à Tabela;
- política inativa/inexistente é recusada;
- proteções anteriores de draft/imutabilidade/RPC-only permanecem.

**NÃO LIVE ainda.** Próxima ação requer autorização explícita do Owner.


## Policy scope guard — LIVE
Autorização explícita recebida e migration aplicada:
- `20260921021027 smart_import_policy_scope_guard_v1`

Pós-apply:
- contract de segurança passou sem exceções;
- função de guarda mantém draft/immutability/RPC-only e agora valida escopo de Instituição, Convênio e Tabela;
- Security Advisor: 0 WARN/ERROR novos; permanecem apenas 2 INFO históricos das tabelas de Platform Admin sem policy pública;
- migration consta em `list_migrations`;
- não reaplicar.


## Smart Import — comparação externa × regra interna
Concluído diretamente pelo ChatGPT, sem Claude e sem DDL:
- `Repasse 1/2/3` pode ser vinculado explicitamente a um Grupo de Comissão;
- cada slot exige semântica explícita: valor final pago ao grupo ou % da comissão recebida;
- cada slot exige unidade explícita; `share_of_received` aceita apenas percentual;
- mapeamento parcial continua fail-closed;
- também existe opção explícita de ignorar os repasses legados e usar somente a política interna;
- os valores externos são apenas observações para comparação, nunca substituem a política interna;
- preview compara externo × interno com estados Confere / Difere / Unidade diferente / Regra diferente / Sem regra interna;
- comparação usa igualdade decimal escalada determinística, sem float;
- Vercel READY no commit `f165112f4e8aa1370d193c83e3b4b0b4bad4a4f6`.

O Smart Import também sugere a política ativa mais específica pelo escopo:
Tabela > Convênio > Instituição > Global.
Empate no mesmo nível exige escolha humana explícita.


## Human Gate — Seller/SUB → proposta/receita esperada
Tripla revisão concluída e migration preparada:
- `20261014_seller_sub_proposal_snapshot_v1.sql`;
- contract `tests/security/seller-sub-proposal-snapshot-contract.sql`;
- desenho `docs/SELLER-SUB-PROPOSAL-SNAPSHOT-V1.md`.

Problema resolvido:
o cadastro de Vendedor/SUB já está LIVE, mas hoje a proposta e `commission_expected` ainda não congelam/aplicam SUB 100/90 etc.

Modelo preparado:
- proposta draft pode receber `seller_id` por RPC governada;
- vendedor só pode ser alterado antes do freeze comercial;
- freeze congela seller/category/seller group e, em área supervisor+, commission group;
- para SUB, cada componente resolve e congela a versão publicada da regra SUB, com fallback `all`;
- SUB sem regra publicada falha fechado;
- fórmula:
  `gross component × upstream/network share × seller_company_share_pct / 100`;
- não-SUB = company share 100%;
- SUB 100% = company share 0%;
- SUB 90% = company share 10%;
- rede/split e SUB permanecem dimensões independentes;
- nenhuma regra atual é consultada depois do snapshot.

Adversarial:
- commission_group_id foi removido dos snapshots de proposta visíveis a membros comuns; permanece apenas no snapshot de componente protegido supervisor+;
- alteração direta de seller continua bloqueada pelo write guard;
- same-tenant FK protege seller e regra;
- eventos financeiros históricos não são reescritos;
- idempotency key existente é preservada.

Validação:
- migration + contract passaram em `BEGIN ... ROLLBACK`;
- migration não consta em `list_migrations`;
- LIVE atual contém 0 propostas, 0 component snapshots, 0 commission_expected, 0 SUB sellers e 0 regras SUB publicadas, então não há backfill econômico existente para reinterpretar.

**NÃO LIVE. Requer autorização explícita.**


## Handoff de sessão — próximo chat
Estado consolidado para retomada gravado em `.ai/NEXT-CHAT-HANDOFF.md`.
O próximo Human Gate é `20261014_seller_sub_proposal_snapshot_v1.sql` (preparada/testada rollback-only, NÃO LIVE).


## Seller/SUB → proposta/receita esperada — LIVE
Aplicada em produção com autorização explícita do Owner:
- `20260921025320 seller_sub_proposal_snapshot_v1`.

Validação pós-apply:
- contract `seller-sub-proposal-snapshot-contract.sql` passou;
- migration consta em `list_migrations`;
- Security Advisor sem WARN/ERROR novo; permanecem somente 2 INFO históricos de Platform Admin.

Efeito funcional:
- proposta draft pode receber vendedor por `assign_proposal_seller`;
- seller fica congelado antes do snapshot comercial;
- SUB resolve regra publicada por componente ou fallback `all`;
- snapshot congela seller, regra SUB, share do SUB e share da empresa;
- expected commission usa o share da empresa já congelado;
- commission group permanece fora do attribution snapshot member-visible.

Aplicação:
- proposal detail ganhou seletor supervisor+ de vendedor/SUB em draft;
- a ação chama somente a RPC governada;
- nenhuma escrita direta em `seller_id` foi adicionada.


## Seller/SUB + rota comercial — integração de aplicação
Concluído diretamente pelo ChatGPT, sem Claude:
- seleção governada de vendedor/SUB em proposta draft;
- apresentação supervisor+ do snapshot congelado SUB/empresa por componente;
- fluxo de congelamento de rota comercial disponível na proposta;
- regra comercial selecionada determina o canal, evitando pares regra/canal inconsistentes na UI;
- filtros de vigência também aplicados na camada de aplicação;
- comissão esperada não oferece nova publicação quando já existe evento esperado;
- perfis sem `canViewCommission` não fazem consulta de ledger na página;
- percentual SUB validado por string no servidor, sem ponto flutuante.

Vercel:
- fluxo de freeze UI READY em `97bf2548f360429a2f52c66af385295d04e5ba06`.

## Human Gate — Proposal/Financial integrity hardening V1
Auditoria adversarial pós-SUB encontrou duas lacunas de defesa em profundidade no LIVE atual:
- a RPC de freeze ainda permite, via chamada direta, uma regra `published` fora da janela `effective_from/effective_until`;
- publicação direta de expected/evidence pode deixar `financial_reconciliation_cases` sem refresh imediato em alguns caminhos.

Pacote preparado:
- `20261015_proposal_financial_integrity_hardening_v1.sql`;
- `tests/security/proposal-financial-integrity-hardening-contract.sql`.

O pacote:
- exige regra publicada **e vigente** dentro da RPC de freeze;
- faz `publish_expected_commission` refrescar conciliação por componente;
- faz `publish_financial_evidence_event` refrescar conciliação para `commission_reported` e `payment_received`;
- remove UPDATE/DELETE de authenticated/anon nas tabelas imutáveis de snapshot comercial.

Validação rollback-only passou integralmente. LIVE permanece sem dados econômicos existentes (0 propostas/snapshots/eventos/casos), e a migration ainda não aparece em `list_migrations`.

**NÃO LIVE. Requer Human Gate explícito.**


## Proposal/Financial integrity hardening V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921031621 proposal_financial_integrity_hardening_v1`.
- Contract pós-apply passou no banco real.
- `freeze_proposal_commercial_route` agora exige regra publicada e dentro de `effective_from/effective_until` também no banco.
- `publish_expected_commission` refresca a conciliação por componente após publicação/idempotência.
- `publish_financial_evidence_event` refresca conciliação em `commission_reported` e `payment_received`.
- authenticated/anon não possuem mais UPDATE/DELETE nos snapshots comerciais imutáveis.
- Security Advisor segue sem WARN/ERROR novo; permanecem somente 2 INFO históricos de Platform Admin.
- A camada de aplicação financeira também deixou de usar ponto flutuante na validação de reversão e na decisão de saldo reversível.


## Simulation lifecycle — próxima Human Gate
Revisão pós-financeiro encontrou um P1 real ainda aberto:
- a aplicação/banco reconhecem `calculated`, `selected`, `expired`, `cancelled`;
- existe write guard, mas não existia RPC governada para encerrar uma simulação calculada;
- o guard anterior ainda permitia transição de `selected` para `expired/cancelled`, o que pode conflitar com uma proposta já criada.

Corrigido sem DDL LIVE:
- parsing de valor de simulação deixou de usar `Number()` e usa decimal determinístico;
- exibição monetária de simulações usa `formatBRL` sem float;
- builds dessas correções estão READY no Vercel.

Preparado e **NÃO LIVE**:
- `supabase/migrations/20261016_simulation_lifecycle_v1.sql`;
- `tests/security/simulation-lifecycle-contract.sql`.

Modelo preparado:
- `close_simulation(id,target)` aceita somente `cancelled` ou `expired`;
- somente simulação `calculated` pode ser encerrada;
- supervisor/manager/admin apenas (fail-closed nesta primeira versão);
- simulação que já tenha proposta é recusada;
- `selected` passa a ser terminal e não pode virar cancelled/expired;
- terminal `expired/cancelled` permanece imutável;
- anon sem EXECUTE; authenticated chama RPC, e RBAC é conferido dentro dela.

Validação:
- migration + contract passaram em `BEGIN -> testes -> ROLLBACK`;
- migration não consta em `list_migrations`;
- Security Advisor continua sem WARN/ERROR novo; somente 2 INFO históricos de Platform Admin.

**Próxima ação irreversível: aplicar `20261016_simulation_lifecycle_v1` LIVE após autorização explícita.**


## Simulation lifecycle V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921032402 simulation_lifecycle_v1`.
- Contract pós-apply passou no banco real.
- `selected` agora é terminal; `expired/cancelled` continuam terminais.
- Encerramento governado aceita somente `calculated -> cancelled|expired`, supervisor/manager/admin, e recusa simulação com proposta vinculada.
- UI concluída: supervisor+ vê ações Cancelar/Expirar apenas em `calculated`; simulações terminais não oferecem Criar proposta.
- Vercel READY no commit funcional `ac367bdf97f8cfd6a933b2ec3ebab1bd873b4c8d`.

## Human Gate atual — Organization direct-write privilege hardening V1
Achado confirmado no LIVE:
- `authenticated` ainda possui INSERT/UPDATE/DELETE em `public.organizations`;
- não há dependência funcional legítima dessa escrita direta na aplicação;
- criação de organização é fluxo Platform Admin via Admin client + `bootstrap_organization_admin`;
- tenant comum precisa apenas de SELECT governado por RLS.

Preparado e **NÃO LIVE**:
- `supabase/migrations/20261017_organization_direct_write_privilege_hardening_v1.sql`;
- `tests/security/organization-direct-write-privilege-contract.sql`.

O pacote:
- revoga INSERT/UPDATE/DELETE de `authenticated` e `anon` em `organizations`;
- preserva SELECT de authenticated;
- verifica que authenticated continua sem EXECUTE em `bootstrap_organization_admin`.

Validação:
- migration + contract passaram em `BEGIN -> testes -> ROLLBACK`;
- `20261017_organization_direct_write_privilege_hardening_v1` não consta em `list_migrations`;
- Security Advisor continua sem WARN/ERROR novo; apenas 2 INFO históricos de Platform Admin.

**Próxima ação requer autorização explícita para aplicar `20261017_organization_direct_write_privilege_hardening_v1` LIVE.**


## Organization direct-write privilege hardening V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921033720 organization_direct_write_privilege_hardening_v1`.
- Contract pós-apply passou no banco real.
- `authenticated` e `anon` não possuem mais INSERT/UPDATE/DELETE em `public.organizations`.
- SELECT de `authenticated` foi preservado.
- `authenticated` continua sem EXECUTE em `bootstrap_organization_admin`.
- Security Advisor continua sem WARN/ERROR novo; permanecem apenas 2 INFO históricos de Platform Admin.

## Próxima decisão de produto/segurança — visibilidade de comissão para agente
Estado verificado:
- UI centraliza visibilidade em `canViewCommission` e hoje é supervisor+;
- porém `authenticated` ainda tem SELECT de tabela inteira em `simulations` e `proposals_v2`;
- assim, `expected_commission_amount` continua tecnicamente legível por um membro autenticado via API, mesmo quando a UI não exibe;
- resolver corretamente não é uma simples revogação de coluna porque RPCs security-invoker existentes leem essas tabelas e podem depender dos grants atuais.

**Nenhuma migration foi criada para isso ainda.** Antes de alterar o contrato de acesso, o Owner precisa decidir se agentes devem ser impedidos também no nível da API de ler comissão esperada. A política atual da UI sugere SIM, mas a decisão de produto deve ser explícita.


## Política de visibilidade de comissão por vendedor — decisão do Owner
Regra aprovada:
- vendedor: vê somente a própria comissão;
- administrador: vê comissão de todos;
- gerente: vê comissão de todos;
- supervisor: vê somente comissão dos vendedores que supervisiona.

### Estado arquitetural encontrado
- `commercial_sellers` não tinha vínculo com usuário autenticado;
- não existia relação supervisor -> vendedores;
- `financial_events`, `financial_reconciliation_cases` e snapshots de componentes davam SELECT amplo a supervisor+;
- `commission_expected` do ledger é receita esperada da empresa, não a comissão individual do vendedor;
- o motor de condição já materializa `commercial_condition_shares.effective_pct` por Grupo de Comissão, que pode ser congelado como comissão individual quando disponível;
- no LIVE atual existem 0 sellers, 0 proposals e 0 commercial_conditions, então não há histórico econômico para migrar/reinterpretar.

### Preparado e NÃO LIVE — Seller commission visibility scope V1
Arquivos:
- `supabase/migrations/20261018_seller_commission_visibility_scope_v1.sql`;
- `tests/security/seller-commission-visibility-scope-contract.sql`.

O pacote preparado:
1. adiciona `commercial_sellers.user_id` com FK tenant-safe para membership;
2. cria `seller_supervisions` para vínculo explícito supervisor -> vendedor, sem DELETE físico;
3. cria RPCs governadas `set_seller_user` e `set_seller_supervision` (admin/manager) com auditoria;
4. cria helper `can_view_seller_commission(org,seller)`:
   - admin/manager = todos;
   - vendedor autenticado = seller ligado ao próprio user_id;
   - supervisor = somente seller em seller_supervisions ativo;
5. cria `proposal_seller_commission_snapshots`, imutável e separado do ledger da empresa;
6. quando a condição tem share inequívoco do Grupo de Comissão, congela `amount = base * effective_pct / 100`;
7. quando o repasse não puder ser determinado com segurança, congela status `unavailable` com motivo, sem estimativa;
8. restringe leitura de `proposal_commercial_component_snapshots`, `financial_events` e `financial_reconciliation_cases` para admin/manager ou supervisor dentro do seu escopo;
9. vendedor não ganha acesso ao ledger da empresa: sua futura UI deve ler somente `proposal_seller_commission_snapshots`.

Validação:
- primeira execução rollback encontrou erro de rowtype e foi corrigida sem qualquer alteração LIVE;
- segunda execução `BEGIN -> migration -> contract -> ROLLBACK` passou integralmente;
- migration ainda não consta em `list_migrations` e NÃO está LIVE.

Limite proposital:
- componente/payout avançado que não resulte em `commercial_condition_shares.effective_pct` não é inferido; fica `unavailable` até integração determinística posterior.

**Próximo Human Gate: aplicar `20261018_seller_commission_visibility_scope_v1` LIVE.**


## Seller commission visibility + access governance — LIVE / CLOSED
Owner policy now authoritative:
- seller sees only own individual commission;
- supervisor sees only commission of explicitly supervised sellers;
- manager/admin see all seller commissions;
- company Finance/ledger is manager/admin only;
- seller commission is separate from company revenue/financial truth.

LIVE migrations:
- `20260921041041 seller_commission_visibility_scope_v1`;
- `20260921041520 seller_access_governed_write_hardening_v1`.

Implemented:
- `commercial_sellers.user_id` tenant-safe binding to active membership;
- `seller_supervisions` explicit supervisor -> seller scope;
- governed RPCs `set_seller_user` and `set_seller_supervision` with audit events;
- direct Data API bypass blocked by trigger gate `corban.seller_access_rpc`;
- `can_view_seller_commission` RLS helper;
- immutable `proposal_seller_commission_snapshots`, distinct from company `financial_events`;
- seller commission snapshot only calculates from proven `commercial_condition_shares.effective_pct`; otherwise records `unavailable`, never estimates;
- supervisor company-finance reads narrowed to supervised proposals at DB level;
- application `canViewCommission` now manager/admin only for company Finance;
- new `/app/comissoes` surface for seller/supervisor/manager/admin using scoped RLS;
- seller catalog now has UI for binding login and supervisor assignments;
- nav exposes Comissões to all authenticated roles, Financeiro only to manager/admin;
- RBAC unit test pins manager/admin-only company ledger visibility.

Validation:
- both migrations passed rollback contracts before LIVE;
- both post-apply contracts passed LIVE;
- Security Advisor still has no new WARN/ERROR; only 2 historical INFO for Platform Admin tables;
- functional Vercel commits for seller access, commissions page, nav, finance wording and RBAC are READY;
- no synthetic sellers/proposals were created in LIVE; production remains free of fake economic data.

Standing authorization note:
Owner authorized future DDL without a new prompt only when strictly necessary to implement/complete this SAME seller commission visibility rule and only after rollback-test + contract. Unrelated DDL, destructive changes, secrets, spend, or external irreversible actions still require a new Human Gate.


## Pilot external readiness — verified after commission wave
Verified LIVE / deploy:
- production login responds HTTP 200 at `https://corban-saas.vercel.app/login`;
- Smart Promotora Ltda. exists and is active; do NOT recreate it;
- reference catalog counts: banks=34, providers=0, agreements=0, products=0, document_types=0;
- seller commission visibility wave is closed and Vercel HEAD is green.

Stale pilot docs were refreshed:
- commission decision marked RESOLVED/LIVE;
- organization direct-write hardening marked RESOLVED/LIVE;
- simulation lifecycle marked RESOLVED/LIVE;
- Smart organization marked RESOLVED;
- Smart Owner Setup no longer tells the Owner to recreate Smart.

### Next real external gates
1. Supabase Auth production configuration:
   - Site URL: `https://corban-saas.vercel.app` (or later custom production domain, if intentionally adopted);
   - redirect: `https://corban-saas.vercel.app/auth/definir-senha`;
   - optional token-hash redirect: `https://corban-saas.vercel.app/auth/confirm`;
   - custom SMTP sender/credentials;
   - Confirm email ON; closed-pilot public signup OFF;
   - password policy >=10 and leaked-password protection if plan supports it;
   - hosting `NEXT_PUBLIC_SITE_URL=https://corban-saas.vercel.app` should be confirmed/set.
2. Complete global reference catalog with REAL data. Do not invent:
   - providers;
   - agreements;
   - products/modalities;
   - document types.
   Banks are already loaded (34).
3. Worker remains intentionally disabled until a real provider is homologated; activation requires secret + scheduler and is a separate external gate.
4. Human browser acceptance still requires real/test credentials after Auth/SMTP is configured.

No unrelated DDL is currently prepared or justified. Do not create fake economic/business records in LIVE merely to exercise the UI.


## Verificação visual do Owner + SMTP adiado
Data: 2026-09-21

Confirmado pelo Owner em produção:
- Corban OS está online e acessível;
- a organização exibida é Smart Promotora Ltda.;
- o dashboard atualizado está visível em produção;
- o menu atualizado inclui Comissões e Financeiro conforme o perfil Administrador;
- a wave recente de comissão/visibilidade está refletida visualmente no sistema.

Decisão operacional:
- NÃO configurar Resend/SMTP agora;
- manter Custom SMTP desligado por enquanto;
- registrar SMTP/Auth e-mail como pendência externa futura;
- quando retomado, continuar de Authentication -> Emails -> SMTP Settings, escolher provedor e configurar sem expor credenciais no chat.

O sistema pode continuar sendo desenvolvido e validado no navegador sem SMTP; convites e recuperação por e-mail ficam como gate externo pendente até essa configuração.


## Incident fix — seller group creation regression
Owner reported that creating a Seller Group returned generic failure and therefore seller creation was blocked.
Root cause verified LIVE: shared trigger `guard_seller_catalog_row()` was used by both `commercial_sellers` and `seller_groups`, but the seller-access hardening dereferenced `NEW.user_id` / `OLD.user_id`. `seller_groups` has no `user_id`, causing the insert to fail.

Fix:
- prepared `20261020_seller_catalog_shared_trigger_regression_fix_v1.sql` + security contract;
- changed user binding inspection to safe `to_jsonb(NEW/OLD)->>'user_id'` so the shared trigger works on both tables;
- rollback harness as authenticated Smart admin proved: Seller Group insert works, seller insert works, direct seller user binding remains blocked;
- applied LIVE as `20260921044435 seller_catalog_shared_trigger_regression_fix_v1` under standing authorization for the same seller-access wave;
- post-apply contract passed;
- Security Advisor unchanged: no new WARN/ERROR, only 2 historical Platform Admin INFO.

No rollback-test business rows persisted in LIVE.


## Seller access bootstrap V1 — PREPARED / NOT LIVE
Owner requirement:
- seller/corretor should not require a second manual "login binding" step;
- when system access is desired, seller creation and access invitation must be one business flow;
- seller-linked login must be role `agent` and can see only own seller commission;
- supervisor/manager/admin scopes remain unchanged.

Prepared:
- `supabase/migrations/20261021_seller_access_bootstrap_v1.sql`;
- `tests/security/seller-access-bootstrap-contract.sql`.

Design:
- `organization_invitations.seller_id` links access invitation to seller;
- `create_seller_with_access(...,p_email)` atomically creates seller + agent invitation when email is supplied;
- access can remain absent for external sellers by passing null email;
- invite acceptance automatically binds `commercial_sellers.user_id` to the verified Auth user;
- existing active non-agent member cannot be silently reused as seller login (`seller_access_requires_agent_role` fail-closed);
- manual `set_seller_user` now accepts only active agent membership;
- seller audit event types are added to the existing append-only admin audit allow-list;
- seller user/supervision audit writes use governed membership context.

Rollback validation:
- several pre-LIVE defects were found and corrected: audit gate context, audit event CHECK, SQL dollar quoting, ambiguous column reference;
- final full harness passed: create seller + create linked agent invitation + simulated service-role acceptance + automatic seller/user binding + own-commission RLS access;
- all test changes rolled back; no synthetic LIVE rows persisted.

Important deployment sequencing:
- do NOT switch production UI to `create_seller_with_access` until this migration is LIVE;
- after LIVE apply, update seller form to default `Criar acesso ao sistema` ON, require email when checked, call new RPC, and attempt invitation email without failing seller creation when SMTP is unavailable.

**Human Gate required before applying this new DDL LIVE.**


## Seller access bootstrap V1 — LIVE + UI migration in progress
Applied LIVE as `20260921050521 seller_access_bootstrap_v1` after explicit Owner authorization.
Post-apply contract passed; Security Advisor unchanged (no new WARN/ERROR; 2 historical Platform Admin INFO only).

Authoritative seller access rule:
- seller/corretor with system access is always an `agent` membership;
- seller can see only own seller commission via scoped RLS;
- supervisor sees only explicitly supervised sellers;
- manager/admin see all seller commissions;
- company Finance remains manager/admin only.

New business flow:
- seller form defaults to `Criar acesso ao sistema` ON;
- e-mail is required only when access is requested;
- `create_seller_with_access` atomically creates seller + linked agent invitation;
- invitation acceptance automatically binds the verified Auth user to `commercial_sellers.user_id`;
- seller record remains valid even if invitation e-mail cannot be sent (SMTP currently deferred);
- external seller can be created without system access by unchecking access;
- old manual login-binding UI is removed from the normal path; access panel now reports active/pending/no-access state and keeps supervisor management.

Application commits include unified seller creation and automatic access state UI. Latest application HEAD before documentation: `afe22a296ec21baedad0384e017cc41333244920`; Vercel build was still BUILDING at last check.


## Seller full profile + payout readiness V1 — LIVE
Applied LIVE as `20260921052901 seller_full_profile_payout_readiness_v1` after explicit Owner authorization.
Post-apply contract passed. Security Advisor unchanged: no new WARN/ERROR; only the 2 historical Platform Admin INFO findings.

Authoritative product rule:
- Corban OS seller registry must be equal-or-better than useful 2Tech seller registration capability, never worse;
- simplification is allowed only when the OS automates/normalizes the same capability without losing information;
- seller registration must support operations, access control, supervision, production, commission and payout readiness.

LIVE seller data model now includes:
- seller_profiles: legal/trade name, e-mail, phone, WhatsApp, birth/opening date, identity/registration, issuer, occupation, notes;
- seller_addresses: versioned current + historical address;
- seller_payment_accounts: versioned bank/Pix payout destination, holder, verification status and effective dates;
- seller_certifications: issuer, number, issue/expiry, status and notes;
- RLS: manager/admin manage; seller can see own profile/payment; supervisor can see supervised seller profile but NOT payout account;
- all writes go through governed RPCs; direct writes are trigger-blocked;
- payment destination replacement closes old version instead of overwriting history.

Application UX:
- /app/cadastros/vendedores remains focused on NEW seller registration and seller-group creation;
- button opens /app/cadastros/vendedores/consulta;
- consultation is compact: search name/CPF-CNPJ + active status + one summary row per seller + Abrir cadastro;
- each seller has dedicated /app/cadastros/vendedores/[id] profile page;
- profile is separated into blocks: Identificação comercial, Dados cadastrais/contato, Endereço, Acesso/supervisão, Dados para pagamento de comissão, Produção/comissão, Certificações;
- payment account history is visible only to manager/admin;
- production block shows seller-linked proposals and calculated seller commission, explicitly warning calculated != paid;
- new seller creation redirects to the dedicated profile page so the operator can complete the full registration immediately.

Important remaining domain gap:
- payout readiness is now in place, but final commission-payment settlement/reporting still requires its own governed payout batch/payment ledger. Do NOT infer `paid to seller` from calculated commission or company financial events.
