# LIVE SCHEMA BASELINE — CORBAN OS V2

**Capturado:** 17/09/2026  
**Supabase:** `corban-saas` / `nhjfrcttzxnphhizlnmc`  
**Objetivo:** registrar o estado factual do banco antes das migrations V2. Este arquivo descreve o que existe; não é o schema-alvo.

## Migration registrada no banco

- `20260917192754_harden_legacy_rls_foundation`

O SQL autoritativo dessa migration ainda não está versionado nesta branch. Não reconstruir o arquivo fingindo equivalência; recuperar de fonte autoritativa antes de versioná-lo.

## Tabelas públicas

| Tabela | Tenant | RLS | Observação |
|---|---|---|---|
| organizations | id | sim | organização legada |
| profiles | organization_id | sim | 1 profile ligado a auth.users |
| clients | organization_id | sim | cliente legado |
| contracts | organization_id | sim | contrato legado |
| import_jobs | organization_id | sim | importação legada |

## Isolamento atual

As cinco policies são permissivas `FOR ALL` e comparam o tenant a `get_user_organization_id()`. A função consulta `profiles.organization_id` para `auth.uid()`, é `SECURITY DEFINER`, `STABLE`, tem `search_path=''` e execução concedida a `authenticated` e `service_role`.

Isto é uma fundação endurecida, não uma certificação de segurança de produção.

## Grants observados

`authenticated` possui SELECT/INSERT/UPDATE/DELETE nas cinco tabelas, condicionado por RLS. `anon` não apareceu com grants nessas tabelas. `service_role` mantém privilégios amplos.

A V2 deve separar policies por operação e autorização de domínio. Não ampliar privilégios para corrigir funcionalidades.

## Integridade observada

- `clients`: UNIQUE `(organization_id, cpf)`, hoje não parcial.
- `contracts.client_id` referencia `clients.id`; o FK não garante sozinho que cliente e contrato pertencem ao mesmo tenant.
- `contracts.user_id` referencia `profiles.id`; o FK não garante sozinho tenant correspondente.
- relações tenant-scoped usam `ON DELETE CASCADE` em vários pontos; isso exige revisão antes de domínios financeiros/auditáveis.
- não há índices dedicados de `organization_id` observados em contracts/import_jobs/profiles além dos índices já listados.
- roles legadas: admin, manager, supervisor, agent.
- status legados de contracts: pendente, em_analise, aprovado, pago, cancelado.

## Divergências V1/V2 já confirmadas

1. O modelo atual associa um usuário a uma organização por `profiles.organization_id`; V2 precisa modelar membership explicitamente para suportar autorização e evolução multi-organização sem confiar em claim stale.
2. O índice de CPF atual não implementa o soft-delete parcial definido no ADR-0005.
3. O banco ainda não possui Customer 360, catálogo Bank/Product/Table, Simulation, Proposal, Document Vault ou Operational Pipeline.
4. `contracts` é legado e não deve ser expandido para fingir que é Proposal + Contract + Production.
5. A migration de hardening está no histórico do Supabase, mas falta a fonte SQL autoritativa no Git.

## Gate para primeira migration V2

Antes de aplicar DDL:
- definir `organization_memberships` e contexto tenant fail-closed;
- criar policies explícitas por operação;
- garantir vínculo tenant-safe nas FKs compostas/validações relevantes;
- preparar teste A/B entre dois tenants;
- preservar compatibilidade/migração dos profiles existentes;
- não apagar nem renomear estrutura legada na primeira migration;
- rollback/forward-fix documentado.

## Próximo alvo

Primeiro incremento seguro: **Tenant/Auth/Membership V2**, aditivo e compatível. Depois: Customer 360.