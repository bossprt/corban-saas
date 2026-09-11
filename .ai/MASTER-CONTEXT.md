# MASTER CONTEXT — CORBAN ENTERPRISE

**Propósito:** contexto mínimo que toda IA/sessão deve ler antes de agir.
**Versão:** 1.0
**Data:** 11/09/2026
**Compatível com Master:** v1.1

---

# 1. O QUE É ESTE PROJETO

SaaS Enterprise para Correspondentes Bancários (Corban).

Não é só CRM. É um **Sistema Operacional para Corbans**.

Multi-tenant, seguro, escalável, com IA supervisionada.

---

# 2. FONTES DE VERDADE

| Arquivo | Papel |
|---|---|
| `/CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` | Conceito (como DEVE ser) |
| `/CORBAN-CURRENT-STATE.md` | Realidade (o que EXISTE) |
| `/.ai/RULES.md` | Como operar |
| `/.ai/DECISIONS.md` | Por que |
| `/.ai/CURRENT-TASK.md` | Foco atual |
| `/.ai/CHANGELOG.md` | O que mudou |

**Ordem de leitura:** master → current-state → rules → current-task.

---

# 3. STACK

- Next.js 16.3.4 (App Router) — atenção: breaking changes
- TypeScript
- Tailwind CSS 4
- Supabase (PostgreSQL + RLS + Storage)
- Drizzle ORM (a instalar)
- BullMQ + Redis (fase futura)
- Vitest + Playwright (a instalar)
- Zod (a instalar)

---

# 4. ESTRUTURA OFICIAL

src/app/ → Next.js App Router
src/lib/ → bibliotecas internas
src/utils/ → utilitários
src/server/ → Domain Services (a criar)
migrations/ → migrations SQL (a criar)
tests/ → testes (a criar)
docs/ → documentação (a criar)
.ai/ → arquivos operacionais de IA

text


**Decisão:** `app/` na raiz deve ser apagado (duplicação com `src/app/`).

---

# 5. REGRAS INVIOLÁVEIS

1. Toda tabela de negócio tem `organization_id`
2. RLS ativado em tudo
3. Backend é soberano em autorização
4. Comissões pagas e audit_logs são imutáveis
5. Toda ação crítica gera evento + auditoria
6. Toda operação financeira é idempotente
7. IA nunca tem acesso irrestrito
8. Nunca confundir "planejado" com "implementado"
9. Nenhuma migration sem teste de rollback
10. Nenhuma lógica de negócio em componente React

---

# 6. ESTADO ATUAL

Ver `/CORBAN-CURRENT-STATE.md`.

**Resumo:**
- Fase: FASE 1 (Fundação técnica) — em andamento
- Repositório: https://github.com/bossprt/corban-saas (privado)
- Next.js + Supabase: montados
- Problemas críticos identificados (6) — resolver antes de avançar
- Drizzle, Zod, Vitest: NÃO instalados
- Migrations: NÃO existem
- RLS: NÃO verificável

---

# 7. O QUE NÃO FAZER

- ❌ Não inventar arquitetura nova sem registrar em `DECISIONS.md`
- ❌ Não criar feature sem responder à Regra de Ouro (12 perguntas)
- ❌ Não alterar o master sem motivo arquitetural registrado
- ❌ Não introduzir dependência que amarre a uma IA específica
- ❌ Não usar `DELETE` em `audit_logs` nem em comissões pagas
- ❌ Não criar tabela de negócio sem `organization_id`
- ❌ Não confiar em validação de frontend para segurança

---

# 8. AO FINAL DE CADA SESSÃO

1. Atualizar `/CORBAN-CURRENT-STATE.md`
2. Registrar decisões em `/.ai/DECISIONS.md`
3. Registrar mudanças em `/.ai/CHANGELOG.md`
4. Atualizar `/.ai/CURRENT-TASK.md`
5. Fazer commit + push
6. Informar próximo passo claramente

---

# 9. MÚLTIPLAS IAs — COMO CONVIVER

Este projeto é trabalhado por várias IAs:

- DeepSeek (chat) — arquiteto
- ChatGPT (chat) — arquiteto
- Claude (chat + Code) — arquiteto + executor
- Gemini (chat + VS Code) — arquiteto + executor
- Llama 3 (local via Continue) — autocomplete e tarefas pequenas

Regras:

- Ninguém sobrescreve decisão de outro sem registrar em `DECISIONS.md`
- Toda IA registra em `CHANGELOG.md`
- Toda IA atualiza `CURRENT-STATE.md` ao terminar
- Se houver conflito, o master vence
- Se o master for omisso, quem decidiu por último documenta

---

# 10. MODELO DE TRABALHO

IA arquiteta (chat) → decide, documenta, gera prompt
↓
IA executora (VS Code) → executa, edita, commita
↓
Usuário → ponte entre os dois
↓
IA arquiteta → analisa resultado, corrige rumo

text

**Regra:** IA arquiteta não executa. IA executora não decide arquitetura.

---

# 11. PRÓXIMO PASSO

Ver `/.ai/CURRENT-TASK.md`.

Atualmente: **Ciclo 1 — limpeza de estrutura de pastas** (`app/` vs `src/app/`).

---

# FIM




