# VERTICAL SLICE V0 — MIGRATION APPLICATION MANIFEST

**Status:** preparado; aplicação bloqueada pelo gate autenticado Tenant A × Tenant B.

## Pré-requisitos já aplicados
1. `harden_legacy_rls_foundation`
2. `organization_memberships_v2`
3. `optimize_membership_rls_auth_initplan`
4. `add_legacy_fk_indexes`

## Gate 0 — obrigatório
Executar `tests/security/TENANT-ISOLATION-A-B.md` com duas identidades autenticadas controladas. Sem 100% de aprovação, parar.

## Ordem de aplicação
1. `20260918_migrate_legacy_rls_to_memberships.sql`
2. `20260918_customer_360_foundation.sql`
3. `20260918_product_catalog_v0.sql`
4. `20260918_simulation_proposal_v0.sql`
5. `20260918_document_vault_v0.sql`
6. `20260918_digitization_pipeline_v0.sql`

A ordem é obrigatória: Customer fornece chaves tenant-safe; Catalog fornece ProductTableVersion; Simulation/Proposal depende dos dois; Documents depende de Proposal + Route; Pipeline depende de Proposal.

## Verificação após cada etapa
- executar o contrato SQL correspondente;
- rodar advisors security/performance;
- inspecionar policies/grants/FKs;
- interromper no primeiro erro; não continuar para “ver se resolve depois”.

## Rollback
Não usar rollback destrutivo automático em produção. Como estas migrations criam estruturas e alteram policy/constraint, o rollback seguro depende do ponto de falha.

Antes de dados reais:
- tabelas V0 recém-criadas podem ser removidas em ordem inversa somente em ambiente controlado;
- policies legadas devem ser restauradas explicitamente se a etapa 1 precisar ser revertida;
- a troca do UNIQUE de CPF deve restaurar a constraint anterior apenas se não houver duplicidades ativas/inativas incompatíveis.

Depois de qualquer dado real:
- não dropar tabelas/colunas automaticamente;
- corrigir com migration forward;
- preservar evidência e histórico.

## Ordem inversa de dependência para recuperação controlada
Pipeline → Document Vault → Simulation/Proposal → Product Catalog → Customer 360 → Legacy RLS.

## Critério de saída
- todos os contratos SQL passam;
- advisors sem novo alerta crítico de segurança;
- nenhum authenticated DELETE em domínios protegidos;
- RLS ativo nas tabelas tenant-scoped;
- FKs compostas tenant-safe presentes;
- A/B continua passando após a cadeia completa.

## Pendências que NÃO bloqueiam staging técnico, mas bloqueiam produção
- RBAC fino por papel;
- guards transacionais de state machine;
- imutabilidade DB de versões publicadas;
- Storage policies do Document Vault;
- Human Gate transacional de documentos → digitação;
- observabilidade/retry/idempotência de integrações externas.
