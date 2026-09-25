# BRIEFING DE RETOMADA — CORBAN ENTERPRISE

Sou o desenvolvedor do projeto Corban Enterprise. Estou retomando o trabalho
após uma pausa e preciso que você leia o contexto abaixo antes de qualquer coisa.

**Última atualização:** 12/09/2026
**Estado:** FASE 1 (Fundação técnica) — em andamento, 2 ciclos concluídos

---

## 1. O QUE É O PROJETO

Corban Enterprise é um SaaS multi-tenant para Correspondentes Bancários.
Objetivo: criar um "Sistema Operacional para Corbans" — não apenas um CRM.

- **Repositório:** https://github.com/bossprt/corban-saas (privado)
- **Diretório local:** `C:\VS CODE - JOSICLEUTOn\corban-saas`

---

## 2. STACK

- Next.js 16.3.4 (App Router) — atenção: breaking changes
- TypeScript
- Tailwind CSS 4
- Supabase (PostgreSQL + RLS)
- Drizzle ORM (a instalar — Ciclo 4)
- Zod (a instalar — Ciclo 4)
- Vitest + Playwright (a instalar — Ciclo 4)

---

## 3. DOCUMENTAÇÃO OBRIGATÓRIA (ler nesta ordem)

1. `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` — fonte de verdade CONCEITUAL
2. `CORBAN-CURRENT-STATE.md` — estado REAL do código
3. `.ai/RULES.md` — regras operacionais
4. `.ai/MASTER-CONTEXT.md` — contexto mínimo
5. `.ai/CURRENT-TASK.md` — foco da sessão atual
6. `.ai/DECISIONS.md` — decisões arquiteturais (ADRs)
7. `.ai/CHANGELOG.md` — histórico de mudanças
8. `docs/NEXT-VERSION-NOTES.md` — breaking changes do Next.js 16.3.4

**REGRA FUNDAMENTAL: MASTER ≠ CURRENT-STATE**
- Master = o que DEVE existir
- Current-state = o que EXISTE agora
- Nunca tratar como implementado algo que só está no master

---

## 4. MODELO DE TRABALHO

- **IA arquiteta** (chat) → decide, documenta, gera prompt
- **IA executora** (VS Code) → executa, edita, commita
- **Usuário** → ponte entre os dois

---

## 5. ESTADO ATUAL (12/09/2026)

### FASE 1 — Fundação técnica (em andamento)

**Concluído:**

1. **Documentação e governança**
   - Master v1.1, current-state, regras, decisões, changelog
   - Briefing de retomada (`.ai/BRIEFING-RETOMADA.md`)

2. **Infraestrutura Next.js**
   - Next.js 16.3.4 + TypeScript + Tailwind + Supabase conectado

3. **Ciclo 1 — Limpeza de estrutura (11/09/2026)**
   - Pasta `app/` da raiz removida
   - `globals.css` e `favicon.ico` movidos para `src/app/`
   - `tsconfig.json` corrigido: `@/*` → `./src/*`
   - Resolve ADR-0009

4. **Ciclo 2 — Documentação do Next.js 16.3.4 (12/09/2026)**
   - `docs/NEXT-VERSION-NOTES.md` criado (136 linhas)
   - Documentadas 10 breaking changes reais (Turbopack padrão, APIs async, middleware→proxy, etc.)
   - Baseado em `node_modules/next/dist/docs/` (fonte primária)

**Ainda não existe:**
- Migrations versionadas
- RLS aplicada
- Multi-tenant funcional
- Drizzle ORM, Zod, Vitest, Playwright
- CRM, esteira, comissão, IA, WhatsApp

### Estrutura de pastas atual
src/app/ — raiz do App Router
src/lib/ — bibliotecas internas
src/utils/supabase/ — middleware.ts, server.ts
middleware.ts — na raiz (auth Supabase)
docs/ — ARCHITECTURE.md, DATABASE.md, RBAC.md, NEXT-VERSION-NOTES.md
.ai/ — arquivos operacionais de IA
raiz — master, current-state, README, configs

text

---

## 6. FERRAMENTAS DISPONÍVEIS

### Setup principal (funcionando)

- **VS Code 1.137** + **Copilot Chat** + **extensão OmniCopilot**
- **OmniRoute** rodando (550+ modelos gratuitos)
- **Modelo:** `openrouter/openrouter/free` (gratuito, sem consumir Claude Pro)
- **Modo Agent** ativo (lê arquivos, edita, executa comandos)

### Setup alternativo

- **Cline** instalado (bug conhecido com OmniRoute: "Invalid API key")
- **Ollama** local com `qwen2.5-coder:7b` e `llama3:latest`
- **Claude Pro** ativo (mas reservado para 2 outros projetos)

### Como subir o OmniRoute

**IMPORTANTE:** o OmniRoute precisa rodar em janela **separada** do VS Code, senão o processo morre ao trocar de aba.

```powershell
# Em uma janela separada do PowerShell:
omniroute
Deixe a janela aberta. O dashboard fica em http://localhost:20128.

7. LIÇÕES APRENDIDAS
Ciclo 1
Cline com qwen2.5-coder:7b sobrescreve arquivos markdown inteiros em vez de editá-los. Para markdown, editar manualmente.

Para editar arquivos grandes no VS Code: sempre Ctrl+A → Delete → Ctrl+V.

Ciclo 2
Agente via Copilot Chat + OmniRoute funciona, mas o OmniRoute tem bugs de streaming (502) que interrompem o agente em tarefas longas.

Editar markdown manualmente ainda é mais confiável para documentos críticos.

O agente precisa de instruções muito específicas ("leia APENAS estes 5 arquivos") para não inventar conteúdo.

Sempre revisar o rascunho do agente antes de commitar. Ele pode inventar citações e conteúdo genérico.

node_modules/next/dist/docs/ é a fonte primária de documentação oficial do Next.js. Usar sempre que possível.

8. PRÓXIMO PASSO — CICLO 3
Ciclo 3 — Alinhamento de contexto de IA

Objetivo: Alinhar arquivos de contexto de IA ao master v1.1.

Passos:

Reescrever PROJECT_CONTEXT.md alinhado ao master v1.1

Atualizar para 11 papéis (hoje fala em 4)

Mencionar Drizzle, Zod, BullMQ, Vitest

Esteira configurável

Comissão via Rules Engine

IA supervisionada

Expandir AGENTS.md com contexto do projeto + link para .ai/RULES.md

Verificar se CLAUDE.md continua apenas apontando para AGENTS.md

Commit: docs(ai): alinhar contexto de IA ao master v1.1

Critério de conclusão: os 3 arquivos revisados, commitados e referenciados no CURRENT-TASK.md.

9. O QUE PRECISO DE VOCÊ AGORA
Por favor:

Confirme que entendeu o contexto acima.

Leia os arquivos principais do repositório (especialmente .ai/CURRENT-TASK.md e CORBAN-CURRENT-STATE.md).

Me diga se podemos começar o Ciclo 3 ou se você identificou algo divergente.

Aguardo sua confirmação antes de prosseguir.

text

## 🎯 Como aplicar

1. **Abre o arquivo** `.ai/BRIEFING-RETOMADA.md` no VS Code
2. **Ctrl+A → Delete → Ctrl+V** com o conteúdo acima
3. **Ctrl+S** (salva)

## ✅ O que mudou em relação à versão anterior

| Seção | O que mudou |
|---|---|
| **Cabeçalho** | Data + estado atualizado (2 ciclos) |
| **Seção 3** | Adicionado `NEXT-VERSION-NOTES.md` na lista |
| **Seção 5** | Adicionado bloco do Ciclo 2 |
| **Seção 6** | Adicionado detalhe de como subir o OmniRoute + setup atual |
| **Seção 7** | Adicionadas lições do Ciclo 2 (agente, 502, rascunhos) |
| **Seção 8** | Atualizado para Ciclo 3 |

## 🎯 Depois de colar

Faz commit:

```powershell
git add .ai\BRIEFING-RETOMADA.md
powershell
git commit -m "docs(ai): atualizar briefing de retomada após Ciclo 2"
powershell
git push