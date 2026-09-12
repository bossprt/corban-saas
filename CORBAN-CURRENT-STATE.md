# CORBAN — CURRENT STATE
## Arquivo de estado atual do desenvolvimento

**Versão do estado:** 0.4
**Data:** 12/09/2026
**Sessão:** Ciclo 2 concluído — documentação da versão do Next.js 16.3.4
**Última alteração:** 12/09/2026 — criação de `docs/NEXT-VERSION-NOTES.md`

---

# REGRAS DE USO DESTE ARQUIVO

1. Este arquivo NUNCA substitui o `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md`.
2. Toda IA/sessão deve LER os dois antes de alterar código.
3. Toda IA/sessão deve ATUALIZAR este arquivo ao final da sessão.
4. Este arquivo responde: "O que EXISTE no código AGORA?"
5. O MASTER responde: "Como DEVE ser?"
6. Não confundir planejado (master) com implementado (este arquivo).
7. Se este arquivo estiver desatualizado, PARAR e perguntar antes de prosseguir.

---

# 1. ESTÁGIO ATUAL

| Item | Status |
|---|---|
| Fase do Roadmap | FASE 1 (Fundação técnica) — em andamento |
| Repositório GitHub | ✅ Criado (https://github.com/bossprt/corban-saas) — PRIVADO |
| Primeiro commit | ✅ Feito em 09/09/2026 |
| Next.js | ✅ Criado (versão 16.3.4 — atenção: breaking changes) |
| Supabase | ✅ Conectado |
| Estrutura de pastas | ✅ Consolidada em `src/app/` (Ciclo 1 concluído) |
| Documentação Next.js 16 | ✅ Criada em `docs/NEXT-VERSION-NOTES.md` (Ciclo 2) |
| Migrations no repositório | ❌ NÃO existem |
| RLS aplicada | ❌ NÃO verificável (não versionada) |
| Multi-tenant | ❌ NÃO implementado |
| Master no repositório | ✅ Salvo em disco |
| Current-state no repositório | ✅ Atualizado em 11/09/2026 |

**Resumo:** Next.js e Supabase montados, estrutura de pastas consolidada. Faltam migrations versionadas, RLS e multi-tenant (próximos ciclos da FASE 1).

---

# 2. ESTRUTURA REAL DO REPOSITÓRIO

corban-saas/
├── src/
│   ├── app/                    ← ✅ ÚNICA raiz de App Router (Next.js 16)
│   │   ├── favicon.ico
│   │   ├── globals.css
│   │   ├── layout.tsx
│   │   ├── page.tsx
│   │   └── login/
│   │       └── page.tsx
│   ├── lib/
│   │   └── supabaseClient.ts
│   └── utils/
│       └── supabase/
│           ├── middleware.ts
│           └── server.ts
├── middleware.ts
├── public/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── DATABASE.md
│   └── RBAC.md
├── .ai/
│   ├── RULES.md
│   ├── MASTER-CONTEXT.md
│   ├── DECISIONS.md
│   ├── CHANGELOG.md
│   └── CURRENT-TASK.md
├── .gitignore
├── AGENTS.md
├── CLAUDE.md
├── PROJECT_CONTEXT.md
├── README.md
├── eslint.config.mjs
├── next.config.ts
├── package.json
├── package-lock.json
├── postcss.config.mjs
├── tsconfig.json
├── CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md
└── CORBAN-CURRENT-STATE.md

---

# 3. STACK REAL INSTALADA

| Dependência | Versão | Status |
|---|---|---|
| next | 16.3.4 | ⚠️ Versão com breaking changes |
| react | 19.2.8 | ✅ |
| react-dom | 19.2.8 | ✅ |
| @supabase/ssr | ^0.12.7 | ✅ |
| @supabase/supabase-js | ^2.116.0 | ✅ |
| lucide-react | ^1.43.0 | ✅ |
| tailwindcss | ^4 | ✅ |
| typescript | ^5 | ✅ |

**NÃO instalado (mas previsto no master):**
- Drizzle ORM
- Zod
- Vitest
- Playwright
- BullMQ
- Redis client

---

# 4. PROBLEMAS IDENTIFICADOS (diagnóstico da sessão inicial)

## 🔴 CRÍTICOS — resolver antes de qualquer código novo

### ✅ 1. Duplicação de estrutura `app/` vs `src/app/` — RESOLVIDO
- ~~Existem duas pastas `app/` concorrentes~~ (resolvido no Ciclo 1, 11/09/2026)
- Estrutura consolidada em `src/app/`
- `app/` da raiz removida
- `tsconfig.json` corrigido: `@/*` → `./src/*`
- Resolve ADR-0009

### 🔴 2. Next.js 16.3.4 — breaking changes
- Versão fora do padrão do que IAs conhecem (treinadas em 14/15)
- `AGENTS.md` avisa, mas não explica o que mudou
- **Ação:** criar `docs/NEXT-VERSION-NOTES.md` documentando diferenças
- **Regra:** toda IA deve ler `node_modules/next/dist/docs/` antes de codar

### 🔴 3. Schema Supabase não versionado
- Não existe pasta `migrations/`, `drizzle/` nem `supabase/migrations/`
- Schema provavelmente vive só no dashboard do Supabase
- Sem versionamento, sem rollback, sem testes
- **Ação:** adotar Drizzle ORM e versionar o schema

### 🔴 4. `PROJECT_CONTEXT.md` divergente do master v1.1
- Fala em 4 papéis; master prevê 11
- Não menciona Drizzle, Zod, BullMQ, Vitest
- Esteira tratada como fixa; master prevê configurável
- Comissão simplificada; master prevê Rules Engine versionado
- IA não mencionada; master prevê agente supervisionado
- **Ação:** substituir por versão alinhada ao master

### 🔴 5. `AGENTS.md` não tem contexto do projeto
- Só tem aviso do Next 16
- IA lê, vê só aviso técnico, não sabe nada sobre Corban
- **Ação:** adicionar contexto do projeto + regras operacionais

### 🔴 6. Login existe mas autenticação não está completa
- `src/app/login/page.tsx` existe
- Sem Zod, sem RBAC, sem organizations, sem membership, sem RLS
- Provavelmente é decorativo
- **Ação:** FASE 2 do roadmap trata disso — não avançar antes

## 🟡 IMPORTANTES — decidir antes de seguir

### 🟡 1. Drizzle vs Supabase CLI para migrations
- Recomendação: Drizzle ORM

### 🟡 2. Monorepo vs app único
- Hoje é app único
- Recomendação: manter app único, migrar quando surgir primeiro worker

### 🟡 3. Onde ficam os arquivos de contexto
- Master + current-state na raiz
- `/docs` para camada intermediária
- `/.ai` para arquivos operacionais de IA

## 🟢 OK

- Next.js + TypeScript + Tailwind funcionando
- Supabase cliente instalado
- Repositório Git criado
- Estrutura mínima de auth (middleware, server)
- Master v1.1 salvo em disco
- Estrutura de pastas consolidada em `src/app/` (Ciclo 1)

## 🔵 FORA DE ESCOPO AGORA

- CRM, esteira, comissão, IA, WhatsApp — nada antes de resolver os 🔴
- BullMQ, Redis — só quando houver primeiro caso de uso real
- Portal do corretor — fase posterior

---

# 5. DECISÕES TOMADAS NESTA SESSÃO

| # | Data | Decisão | Observação |
|---|---|---|---|
| 1 | 11/09/2026 | Seguir o master v1.1 como fonte de verdade conceitual | |
| 2 | 11/09/2026 | Estrutura oficial: manter `src/app/`, apagar `app/` da raiz | ✅ Executado em 11/09/2026 (Ciclo 1) |
| 3 | 11/09/2026 | Modelo de trabalho: IA arquiteta no chat + IA executora no VS Code | Cline + Ollama qwen2.5-coder:7b |
| 4 | 11/09/2026 | Corrigir `tsconfig.json`: alias `@/*` → `./src/*` | ✅ Executado em 11/09/2026 (Ciclo 1) |
| 5 | 11/09/2026 | Não usar Cline (7B) para editar markdown existente | Aprendizado: sobrescreve arquivos inteiros |

---

# 6. DECISÕES PENDENTES

| # | Pergunta | Recomendação | Prazo |
|---|---|---|---|
| P1 | Migrations: Drizzle ou Supabase CLI? | Drizzle | Antes de seguir |
| P2 | Monorepo ou app único? | App único por ora | Antes do primeiro worker |
| P3 | Substituir `PROJECT_CONTEXT.md`? | Sim | Ciclo 3 |
| P4 | Instalar Cline ou usar Continue puro? | Decidido: Cline instalado | ✅ Resolvido |

---

# 7. FERRAMENTAS DO DESENVOLVEDOR

| Ferramenta | Uso |
|---|---|
| VS Code | Editor principal |
| Cline (extensão) | IA executora no VS Code |
| Continue (extensão) | IA no VS Code (legado) |
| Ollama + qwen2.5-coder:7b | Modelo local |
| GitHub | Repositório privado |
| Supabase | Banco de dados e auth |

**Limitação conhecida:** Cline com `qwen2.5-coder:7b` **sobrescreve arquivos inteiros** em vez de editá-los. Para edições de markdown, preferir edição manual ou modelo ≥14B. Ver decisão #5 da seção 5.

---

# 8. PRÓXIMO PASSO CONCRETO

**Ciclo 3 — Alinhamento de contexto de IA**

1. Reescrever `PROJECT_CONTEXT.md` alinhado ao master v1.2
2. Expandir `AGENTS.md` com contexto do projeto + link para `/.ai/RULES.md`
3. Verificar se `CLAUDE.md` continua apenas apontando para `AGENTS.md`
4. Commit: `docs(ai): alinhar contexto de IA ao master v1.2`

**Critério de conclusão:** arquivo criado, commitado e referenciado no `CURRENT-TASK.md`.

---

# 9. ERROS CONHECIDOS

Nenhum erro de runtime registrado até agora. Problemas identificados são estruturais, não de execução.

---

# 10. TESTES

Nenhum teste criado. Vitest e Playwright ainda não instalados.

---

# 11. AMBIENTES

| Ambiente | URL | Status |
|---|---|---|
| Local | http://localhost:3000 | ✅ Deve funcionar |
| Dev | — | ❌ Não configurado |
| Staging | — | ❌ Não configurado |
| Produção | — | ❌ Não configurado |

---

# 12. HISTÓRICO DE SESSÕES

| # | Data | O que foi feito | Próximo passo definido |
|---|---|---|---|
| 1 | 11/09/2026 | Diagnóstico do repositório; identificação de 6 problemas críticos e 4 pendências; decisão de consolidar em `src/app/` | Ciclo 1: limpeza de estrutura |
| 2 | 11/09/2026 | Ciclo 1 concluído: pasta `app/` da raiz removida, `globals.css` e `favicon.ico` movidos para `src/app/`, `tsconfig.json` corrigido (`@/*` → `./src/*`). Registrada a limitação do Cline (7B) para edições de markdown. | Ciclo 2: documentação Next.js 16.3.4 |
| 3 | 12/09/2026 | Ciclo 2 concluído: criado `docs/NEXT-VERSION-NOTES.md` documentando as breaking changes do Next.js 16.3.4 (Turbopack por padrão, APIs assíncronas, middleware→proxy, etc.) com base na documentação local. | Ciclo 3: alinhamento de contexto de IA |

---

# 13. INSTRUÇÕES PARA A PRÓXIMA IA/SESSÃO

Ao retomar o projeto:

1. LER `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md`
2. LER `CORBAN-CURRENT-STATE.md` (este arquivo)
3. VERIFICAR se o repositório real bate com o que este arquivo descreve
4. Se houver divergência: atualizar este arquivo ANTES de codar
5. ANTES de codar: confirmar o "Próximo Passo" com o usuário
6. AO TERMINAR: atualizar as seções 1, 2, 3, 4, 5, 6, 8, 12 deste arquivo
7. **NUNCA** usar o Cline (com modelo 7B) para editar arquivos existentes — ele sobrescreve arquivos inteiros. Preferir edição manual ou modelo ≥14B.

---

# FIM
