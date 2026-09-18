# CURRENT TASK — CORBAN OS V2

**Atualização:** 17/09/2026  
**Branch:** `architecture/corban-os-master-v2`

## Foco
Construir a fundação executável e segura da primeira fatia vertical.

## Concluído
- [x] Contexto V2 e MASTER V2 consolidados.
- [x] AGENTS e MASTER-CONTEXT apontam primeiro para V2.
- [x] Supabase correto identificado: `corban-saas` / `nhjfrcttzxnphhizlnmc`.
- [x] Migration viva confirmada: `20260917192754_harden_legacy_rls_foundation`.
- [x] Inventário factual de tabelas, colunas, RLS, policies, grants, índices e constraints registrado em `docs/LIVE-SCHEMA-BASELINE-V2.md`.
- [x] Divergências do legado identificadas: membership simples em profiles, CPF não parcial, FKs sem garantia tenant-composta e grants/policies ainda genéricos.
- [x] ADR-0011 adotado: membership explícito + tenant context fail-closed.
- [x] Confirmado que Drizzle, Zod, Vitest e Playwright não estão instalados nesta branch.

## Próxima execução
1. Especificar migration aditiva Tenant/Auth/Membership V2 e estratégia de forward-fix/rollback.
2. Criar teste de isolamento A/B como gate antes de aplicar a migration.
3. Recuperar SQL autoritativo da migration de hardening; não inventar cópia.
4. Aplicar apenas migration aditiva após validação técnica; nenhuma remoção do legado.
5. Implementar Customer 360 sobre a fundação validada.
6. Seguir Bank/Product/Table → Simulation → Proposal → Documents → Digitization → Pipeline.

## Gates
Não alterar `main`. Não executar migration destrutiva. Não publicar produção. Não inserir secrets. Operação irreversível, gasto, billing/money ou mudança externa relevante exige Human Gate.

## Primeira entrega vertical
`Login/Tenant → Customer 360 → Bank/Product/Table → Simulation → Proposal → Documents → Send to Digitization → Operational Desk → Pipeline`
