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