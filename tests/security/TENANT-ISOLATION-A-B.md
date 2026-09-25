# TENANT ISOLATION A/B HARNESS

**Status:** bloqueado por ausência de identidades de teste autenticadas; não criar usuários artificiais no projeto principal apenas para satisfazer o teste.

## Estado observado em 18/09/2026
- auth.users: 0
- organizations: 0
- organization_memberships: 0

## Cenário obrigatório antes da troca das policies legadas

Criar em ambiente controlado:
- Tenant A + User A + membership A ativo
- Tenant B + User B + membership B ativo
- um registro não sensível de teste por tenant

Validar com JWT real de cada usuário:
1. A lê A e não lê B.
2. B lê B e não lê A.
3. A não consegue INSERT com organization_id=B.
4. A não consegue UPDATE movendo registro A→B.
5. usuário sem membership não lê nem escreve dados tenant-scoped.
6. membership revoked/inactive perde acesso.
7. organization_id enviado pelo cliente nunca concede acesso sem membership.
8. authenticated não consegue criar/alterar/revogar organization_memberships diretamente.

## Critério
100% das asserções precisam passar. Evidência deve ser registrada antes de aplicar `20260918_migrate_legacy_rls_to_memberships.sql`.

## Observação
A migration de policies foi preparada no Git, mas permanece deliberadamente não aplicada até este gate.