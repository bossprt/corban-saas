# CURRENT TASK — CORBAN OS V2

**Atualização:** 17/09/2026  
**Branch:** `architecture/corban-os-master-v2`

## Foco
Validar e aplicar de forma controlada a fundação Tenant/Auth/Membership V2; depois iniciar Customer 360.

## Concluído
- [x] Contexto V2, MASTER V2 e bootstrap dos agentes consolidados.
- [x] Supabase correto reconciliado: `corban-saas` / `nhjfrcttzxnphhizlnmc`.
- [x] Baseline vivo documentado em `docs/LIVE-SCHEMA-BASELINE-V2.md`.
- [x] ADR-0011: membership explícito + tenant fail-closed.
- [x] Migration aditiva versionada em `supabase/migrations/20260917_organization_memberships_v2.sql`.
- [x] Plano/forward-fix documentado em `docs/TENANT-AUTH-MEMBERSHIP-V2.md`.
- [x] Contrato de teste criado em `tests/security/tenant-membership-isolation.sql`.
- [x] Preflight do banco: tabela membership ausente, 0 profiles legados, pgcrypto disponível e DDL possível.
- [x] Nenhuma DDL V2 aplicada ainda.

## Próxima execução
1. Revisão adversarial final do SQL versionado.
2. Aplicar migration aditiva via mecanismo de migration do Supabase.
3. Inspecionar schema/policies/grants pós-migration.
4. Executar testes de segurança possíveis sem criar usuários artificiais de produção; preparar harness A/B controlado para autenticação.
5. Só depois migrar policies legadas em migration separada.
6. Iniciar Customer 360.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Não fabricar usuários/dados reais sem necessidade. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.
