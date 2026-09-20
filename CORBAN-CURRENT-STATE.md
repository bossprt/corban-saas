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
