# BRIEFING DE RETOMADA — PROJETO CORBAN ENTERPRISE

Sou o desenvolvedor do projeto Corban Enterprise. Estou retomando o trabalho
após uma pausa e preciso que você leia o contexto abaixo antes de qualquer coisa.

## 1. O QUE É O PROJETO

Corban Enterprise é um SaaS multi-tenant para Correspondentes Bancários.
Objetivo: criar um "Sistema Operacional para Corbans" — não apenas um CRM.

Repositório: https://github.com/bossprt/corban-saas (privado)
Diretório local: C:\VS CODE - JOSICLEUTOn\corban-saas

## 2. STACK

- Next.js 16.3.4 (App Router) — atenção: breaking changes
- TypeScript
- Tailwind CSS 4
- Supabase (PostgreSQL + RLS)
- Drizzle ORM (a instalar)
- Zod (a instalar)
- Vitest + Playwright (a instalar)

## 3. DOCUMENTAÇÃO OBRIGATÓRIA (leia nesta ordem)

No repositório, os arquivos-chave são:

1. CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md — fonte de verdade CONCEITUAL
2. CORBAN-CURRENT-STATE.md — estado REAL do código
3. .ai/RULES.md — regras operacionais
4. .ai/MASTER-CONTEXT.md — contexto mínimo
5. .ai/CURRENT-TASK.md — foco da sessão atual
6. .ai/DECISIONS.md — decisões arquiteturais (ADRs)
7. .ai/CHANGELOG.md — histórico de mudanças

REGRA FUNDAMENTAL: MASTER ≠ CURRENT-STATE
- Master = o que DEVE existir
- Current-state = o que EXISTE agora
- Nunca tratar como implementado algo que só está no master

## 4. MODELO DE TRABALHO

- IA arquiteta (chat) → decide, documenta, gera prompt
- IA executora (VS Code) → executa, edita, commita
- Usuário → ponte entre os dois

## 5. ESTADO ATUAL (11/09/2026)

**FASE 1 (Fundação técnica) — em andamento**

### Concluído:
- Documentação e governança (todos os 7 arquivos acima commitados)
- Infraestrutura Next.js + TypeScript + Tailwind + Supabase
- **Ciclo 1 concluído (11/09/2026):** consolidação da estrutura em src/app/
  - Pasta app/ da raiz removida
  - globals.css e favicon.ico movidos para src/app/
  - tsconfig.json corrigido: alias @/* agora aponta para ./src/*
  - Resolve ADR-0009
  - Commits: b0c6c0e (refactor) e 4fdc2d9 (chore)

### Ainda não existe:
- Migrations versionadas
- RLS aplicada
- Multi-tenant funcional
- Drizzle ORM, Zod, Vitest, Playwright
- CRM, esteira, comissão, IA, WhatsApp

### Estrutura de pastas atual:
- src/app/ — raiz do App Router (layout.tsx, page.tsx, login/page.tsx, globals.css, favicon.ico)
- src/lib/ — bibliotecas internas
- src/utils/supabase/ — middleware.ts, server.ts
- middleware.ts — na raiz (auth Supabase)
- docs/ — ARCHITECTURE.md, DATABASE.md, RBAC.md
- .ai/ — arquivos operacionais de IA
- Raiz — master, current-state, README, configs

## 6. FERRAMENTAS DISPONÍVEIS

- VS Code + Cline (com Ollama qwen2.5-coder:7b local)
- Ollama rodando localmente
- Git + GitHub

## 7. LIÇÕES APRENDIDAS NO CICLO 1 (importante!)

- Cline com qwen2.5-coder:7b SOBRESCREVE arquivos markdown inteiros
  em vez de editá-los. NÃO confiável para editar arquivos existentes.
- Para editar arquivos grandes no VS Code: sempre Ctrl+A → Delete → Ctrl+V
- git checkout HEAD -- <arquivo> é a rede de segurança
- PowerShell isolado quebra acentos; terminal do VS Code é mais seguro

## 8. PRÓXIMO PASSO — CICLO 2

**Ciclo 2 — Documentação da versão do Next.js 16.3.4**

Objetivo: criar docs/NEXT-VERSION-NOTES.md documentando breaking changes
da versão 16.3.4 do Next.js.

Passos previstos:
1. Verificar o que existe em node_modules/next/dist/docs/
2. Documentar mudanças relevantes (App Router, middlewares, cache, APIs)
3. Referenciar os docs locais no arquivo
4. Commit

## 9. O QUE PRECISO DE VOCÊ AGORA

Por favor:
1. Confirme que entendeu o contexto acima
2. Leia os 3 arquivos principais do repositório (links raw abaixo, se precisar)
3. Me diga se podemos começar o Ciclo 2 ou se você identificou algo divergente

Links raw dos arquivos principais:
- https://raw.githubusercontent.com/bossprt/corban-saas/main/.ai/CURRENT-TASK.md
- https://raw.githubusercontent.com/bossprt/corban-saas/main/CORBAN-CURRENT-STATE.md

(Se os links raw não carregarem, eu colo o conteúdo na próxima mensagem.)

Aguardo sua confirmação antes de prosseguir.