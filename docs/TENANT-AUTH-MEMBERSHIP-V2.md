# TENANT / AUTH / MEMBERSHIP V2 — MIGRATION PLAN

**Status:** migration preparada no Git; ainda não aplicada.
**Data:** 17/09/2026

## Objetivo
Adicionar membership explícito sem remover `profiles.organization_id` nem alterar as policies legadas das tabelas existentes.

## Por que aditiva
A primeira mudança V2 cria apenas `organization_memberships`, índices, helper de membership e policy de leitura própria. Não troca ainda o mecanismo RLS de clients/contracts/import_jobs/organizations/profiles. Isso reduz blast radius e permite validar o novo contexto antes da migração das policies.

## Estado do banco antes da aplicação
Na verificação imediatamente anterior, `organization_memberships` não existe e `profiles` contém 0 registros. Portanto o backfill é esperado como no-op neste ambiente hoje; permanece no SQL para compatibilidade com outros estados/ambientes.

## Modelo de autorização
Usuário autenticado pode ler somente os próprios memberships ativos. Não recebe grants diretos para criar/alterar/revogar membership. Mutação fica no backend privilegiado e deverá ganhar serviço de domínio + RBAC + auditoria antes de ser exposta pela aplicação.

O helper `is_active_organization_member(uuid)` responde apenas à sessão `auth.uid()`; um organization_id fornecido pelo cliente não concede acesso sozinho.

## Forward-fix / rollback
A migration é aditiva. Se houver falha antes de uso pela aplicação, o rollback operacional é parar de consumir o novo modelo e aplicar uma migration de compensação separada. Não editar migration já aplicada. Não remover legado no mesmo ciclo.

Quando houver dados reais de membership, drop destrutivo não será rollback padrão. Corrigir por forward-fix.

## Gate
Antes de migrar policies existentes para membership:
1. aplicar migration aditiva;
2. executar o contrato em `tests/security/tenant-membership-isolation.sql` em ambiente controlado;
3. validar A/B com dois usuários/tenants;
4. só então escrever migration separada para clients/organizations/profiles e futuros domínios.

## Fora deste incremento
Customer 360, catálogo, Proposal, Contract V2, financeiro e troca das policies legadas.