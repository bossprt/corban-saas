# CURRENT TASK — CORBAN ENTERPRISE

**Última atualização:** 11/09/2026
**Fase:** FASE 1 (Fundação técnica)
**Sessão anterior:** Ciclo 1 concluído — limpeza de estrutura de pastas

---

# 🎯 FOCO ATUAL

**Ciclo 2 — Documentação da versão do Next.js**

Criar `/docs/NEXT-VERSION-NOTES.md` documentando breaking changes da versão 16.3.4.

---

# ✅ CONCLUÍDO ATÉ AGORA

Documentação e governança:
- [x] `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` salvo e commitado
- [x] `CORBAN-CURRENT-STATE.md` salvo e commitado
- [x] `/.ai/RULES.md` salvo e commitado
- [x] `/.ai/MASTER-CONTEXT.md` salvo e commitado
- [x] `/.ai/DECISIONS.md` salvo e commitado
- [x] `/.ai/CHANGELOG.md` salvo e commitado
- [x] `/.ai/CURRENT-TASK.md` (este arquivo)

Infraestrutura Next.js (feita na sessão 0, antes desta):
- [x] Next.js 16.3.4 criado
- [x] TypeScript + Tailwind configurados
- [x] Supabase conectado
- [x] Repositório GitHub privado

Ciclo 1 — Limpeza de estrutura:
- [x] Auditar `app/` vs `src/app/`
- [x] Comparar arquivos duplicados
- [x] Apresentar plano de consolidação ao usuário
- [x] Confirmar com usuário antes de apagar nada
- [x] Executar consolidação (manter `src/app/`, apagar `app/` da raiz)
- [x] Rodar `npm run dev` e confirmar que sobe
- [x] Commit: `refactor: consolidar estrutura em src/app`

---

# 🔨 PRÓXIMOS PASSOS (em ordem)

## Ciclo 2 — Documentação de versão do Next.js

- [ ] Criar `/docs/NEXT-VERSION-NOTES.md`
- [ ] Documentar breaking changes da versão 16.3.4
- [ ] Referenciar `node_modules/next/dist/docs/`
- [ ] Commit

## Ciclo 3 — Alinhamento de contexto de IA

- [ ] Reescrever `PROJECT_CONTEXT.md` alinhado ao master v1.2 (quando existir)
- [ ] Expandir `AGENTS.md` com contexto do projeto + link para `/.ai/RULES.md`
- [ ] Verificar se `CLAUDE.md` continua apenas apontando para `AGENTS.md`
- [ ] Commit

## Ciclo 4 — Instalação de dependências base

- [ ] Instalar Drizzle ORM + Drizzle Kit
- [ ] Instalar Zod
- [ ] Instalar Vitest + Playwright
- [ ] Configurar `drizzle.config.ts`
- [ ] Configurar scripts de teste no `package.json`
- [ ] Commit

## Ciclo 5 — Primeira migration

- [ ] Definir schema inicial: `organizations`, `users`, `memberships`, `roles`, `permissions`
- [ ] Criar migration SQL
- [ ] Aplicar RLS nas tabelas
- [ ] Testar isolamento por tenant
- [ ] Commit

## Ciclo 6 — Camada intermediária de docs

- [ ] Criar `/docs/BUSINESS-RULES.md`
- [ ] Commit

---

# 🚧 BLOQUEIOS ATUAIS

Nenhum bloqueio técnico.

**Bloqueio de decisão:** antes do Ciclo 4, decidir:
- P7 (do DECISIONS.md): adicionar Gemini no Continue para modo Agent?
  - Recomendação: sim — Llama 3 local é limitado para tarefas estruturais.

**Nota de aprendizado (Ciclo 1):**
O Cline com `qwen2.5-coder:7b` **sobrescreveu arquivos inteiros** em vez de editá-los, destruindo `.ai/CHANGELOG.md`, `.ai/CURRENT-TASK.md` e `CORBAN-CURRENT-STATE.md`. Todos foram restaurados via `git checkout HEAD -- <arquivo>`.

**Aprendizado:** para tarefas de edição de markdown, preferir edição manual. Considerar modelo 14B para os próximos ciclos (ver P7 e próximo ciclo).

---

# 📌 DECISÕES PENDENTES

Ver `/.ai/DECISIONS.md` → seção "DECISÕES PENDENTES".

| # | Pergunta | Recomendação |
|---|---|---|
| P1 | Monorepo ou app único? | App único por ora |
| P2 | Supabase Auth ou Auth.js? | Supabase Auth |
| P3 | Storage: Supabase puro ou S3? | Supabase puro |
| P4 | Provedor WhatsApp? | Meta Cloud API |
| P5 | Provedor de assinatura? | Clicksign |
| P6 | Hospedagem final? | Vercel + Supabase |
| P7 | Adicionar Gemini no Continue? | Sim |

---

# 🎓 CRITÉRIO DE CONCLUSÃO DA FASE 1

- [x] `npm run dev` sobe sem erros
- [ ] `npm test` roda (mesmo sem testes reais)
- [x] `npm run lint` passa
- [ ] CI verde no GitHub Actions
- [ ] Supabase conectado com pelo menos uma migration aplicada
- [ ] RLS funcionando e testada
- [x] Estrutura de pastas única (`src/app/`)
- [ ] Drizzle configurado
- [ ] Zod configurado

---

# 👉 INSTRUÇÕES PARA A PRÓXIMA IA

1. Ler `/CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md`
2. Ler `/CORBAN-CURRENT-STATE.md`
3. Ler `/.ai/RULES.md`
4. Ler `/.ai/MASTER-CONTEXT.md`
5. Ler este arquivo (CURRENT-TASK)
6. Começar pelo **Ciclo 2 — Documentação da versão do Next.js**
7. Confirmar cada ciclo com o usuário antes de avançar
8. Ao final de cada ciclo, atualizar `CHANGELOG.md` e fazer commit

**Modelo de trabalho:** IA arquiteta no chat + IA executora no VS Code + usuário como ponte.

---

# FIM