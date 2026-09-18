# MASTER CONTEXT — CORBAN OS V2

**Propósito:** contexto mínimo de retomada para qualquer IA/agente.
**Atualizado:** 17/09/2026
**Estado:** transição V1 → V2 em execução.

## Ordem de leitura
1. `/CORBAN-OS-PROJECT-CONTEXT-V2.md`
2. `/CORBAN-OS-MASTER-V2.md`
3. `/.ai/RULES.md`
4. `/.ai/DECISIONS.md`
5. `/.ai/CURRENT-TASK.md`
6. `/CORBAN-CURRENT-STATE.md` apenas como documento histórico a reconciliar com Git, código, migrations e banco vivo.

## Fronteiras
- Corban OS: fonte de verdade da operação bancária.
- Growth OS: aquisição, campanhas, tracking e atribuição.
- SmartMatch: conversão, atendimento, follow-up e recuperação.
- Cérebro/Control Tower: orquestração de projetos/agentes.

Projetos permanecem separados e integram por contratos/APIs/eventos versionados. Não criar acoplamento direto de banco entre eles.

## Stack observada
Next.js 16.3.4, React 19, TypeScript, Tailwind CSS 4 e Supabase/PostgreSQL/RLS. No branch V2, Drizzle, Zod, Vitest e Playwright ainda não devem ser tratados como implementados.

## Estado factual do Supabase Corban
Projeto `corban-saas`: `nhjfrcttzxnphhizlnmc`.

Verificado em 17/09/2026:
- migration registrada: `20260917192754_harden_legacy_rls_foundation`;
- tabelas públicas: `organizations`, `profiles`, `clients`, `contracts`, `import_jobs`;
- RLS habilitado nas cinco;
- políticas legadas usam `get_user_organization_id()`;
- função SECURITY DEFINER/STABLE com `search_path=''`; execução para authenticated/service_role, não PUBLIC/anon;
- isto é fundação legada endurecida, não certificação de isolamento multi-tenant de produção.

A migration existe no banco, mas ainda precisa ser reconciliada/versionada no Git a partir de SQL autoritativo. Não reconstruir seu conteúdo por suposição.

## Primeira entrega vertical
`Login/Tenant → Customer 360 → Bank/Product/Table → Simulation → Proposal → Documents → Send to Digitization → Operational Desk → Pipeline`

## Invariantes imediatos
Tenant isolation fail-closed; backend soberano em autorização; RLS não substitui autorização de domínio; dinheiro nunca Float; propostas preservam snapshots/versionamento; eventos externos idempotentes/auditáveis; histórico financeiro não é apagado ou reescrito silenciosamente; segredos fora de Git/frontend/logs/tabelas de negócio; IA não altera verdade financeira silenciosamente; nunca confundir planejado com implementado.

## Execução
Trabalhar em branch isolada e não alterar `main` diretamente. DDL destrutivo, publicação, gasto, segredo, billing/money ou ação externa irreversível exigem Human Gate. O próximo passo executável vem de `/.ai/CURRENT-TASK.md`.
