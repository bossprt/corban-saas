# RULES — CORBAN ENTERPRISE

Regras operacionais para IAs e desenvolvedores que atuam neste projeto.

**Versão:** 1.0
**Data:** 11/09/2026
**Compatível com Master:** v1.1
**Aplica-se a:** Qualquer IA (DeepSeek, ChatGPT, Claude, Gemini, Llama local, etc.) e qualquer desenvolvedor humano

---

# 0. LEIA ISTO PRIMEIRO

Antes de qualquer ação, leia na ordem:

1. `/CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` — como o sistema DEVE ser
2. `/CORBAN-CURRENT-STATE.md` — o que EXISTE no código agora
3. `/.ai/RULES.md` — este arquivo — como operar
4. `/.ai/CURRENT-TASK.md` — foco da sessão atual

Não pule nenhum. Não assuma. Não invente.

---

# 1. REGRA FUNDAMENTAL

**MASTER ≠ CURRENT-STATE**

- O master descreve o que **deve** existir.
- O current-state descreve o que **existe**.
- Nunca tratar como implementado algo que só está no master.
- Nunca assumir que algo existe sem verificar o current-state.

---

# 2. ANTES DE AGIR

Checklist obrigatório:

- [ ] Li o master v1.1
- [ ] Li o current-state
- [ ] Li estas regras
- [ ] Li o CURRENT-TASK
- [ ] Verifiquei se o código real bate com o current-state
- [ ] Se há divergência, atualizei o current-state ANTES de codar
- [ ] Confirmei com o usuário o que vou fazer

Se algum item acima está ❌, **pare e resolva antes**.

---

# 3. DURANTE O TRABALHO

## 3.1 Regras invioláveis

1. Nenhuma tabela de negócio sem `organization_id`
2. Nenhuma query sem filtro de tenant
3. Nenhuma autorização apenas no frontend
4. Nenhuma operação financeira sem idempotência
5. Nenhuma ação da IA sem auditoria
6. Nenhuma migration sem teste de rollback
7. Nenhum `DELETE` em `audit_logs` nem em comissões pagas
8. Nenhuma alteração em `ProductTableVersion` após publicada
9. Nenhum uso de `any` sem justificativa em comentário
10. Nenhuma lógica de negócio em componente React

## 3.2 Regra de Ouro

Toda nova funcionalidade deve responder às 12 perguntas (master, seção 55):

1. Quem pode acessar?
2. Qual tenant possui os dados?
3. Qual regra de negócio?
4. Qual evento é gerado?
5. Precisa de auditoria?
6. Precisa de SLA?
7. Pode ser automatizada?
8. A IA poderá atuar futuramente?
9. Como será testada?
10. Como será retomada por outra IA?
11. Qual o custo operacional (storage, IA, filas)?
12. Como se comporta com 10.000 tenants e 1M de propostas?

Se não souber responder, **não implemente ainda**.

## 3.3 Escopo

- Não criar feature fora do CURRENT-TASK
- Não instalar dependências sem aprovação
- Não alterar `package.json` sem avisar
- Não alterar `next.config.ts`, `tsconfig.json`, `drizzle.config.ts` sem avisar
- Não commitar sem o usuário pedir

---

# 4. AO FINAL DE CADA SESSÃO

Checklist obrigatório:

- [ ] Atualizei `CORBAN-CURRENT-STATE.md` se algo mudou no código
- [ ] Registrei decisões novas em `/.ai/DECISIONS.md`
- [ ] Registrei mudanças em `/.ai/CHANGELOG.md`
- [ ] Atualizei `/.ai/CURRENT-TASK.md` para a próxima sessão
- [ ] Informei o usuário claramente: o que foi feito, o que não foi, qual o próximo passo
- [ ] O código está commitado e o push foi feito

Se algum item acima está ❌, **avise o usuário antes de encerrar**.

---

# 5. COMUNICAÇÃO

- Sempre dizer o que foi feito e o que NÃO foi
- Nunca confundir "planejado" com "implementado"
- Nunca inventar arquitetura sem registrar em `DECISIONS.md`
- Nunca assumir decisão do usuário — perguntar
- Nunca usar linguagem vaga como "acho que", "talvez", "deve funcionar"
- Se não sabe, dizer "não sei" — não inventar

---

# 6. CÓDIGO

## 6.1 Estilo

- TypeScript estrito
- Sem `any` sem justificativa
- Sem `console.log` em produção (usar pino)
- Sem código comentado sem motivo
- Sem `TODO` sem dono

## 6.2 Estrutura

- `src/app/` é a raiz da aplicação Next.js (decisão oficial)
- `src/lib/` para bibliotecas internas
- `src/utils/` para utilitários
- `src/server/` para Domain Services e Server Actions (a criar)
- `migrations/` para migrations SQL (a criar)
- `tests/` para testes (a criar)

## 6.3 Convenções

| Item | Convenção |
|---|---|
| Tabelas | `snake_case` plural |
| Colunas | `snake_case` |
| Tipos TS | `PascalCase` |
| Eventos | `PascalCase` |
| Arquivos TS | `kebab-case` |
| Componentes React | `PascalCase` |
| Rotas | `kebab-case` |
| Migrations | `YYYYMMDDHHMMSS_descricao.sql` |

## 6.4 Camadas

- Frontend: só apresentação
- API/BFF: validação + orquestração
- Domain Services: regras de negócio
- Repository: acesso a dados via Drizzle
- Nunca chamar banco direto de componente React

---

# 7. SEGURANÇA

- RLS sempre ativado
- Backend é soberano em autorização
- Storage privado
- Segredos nunca no repositório
- Toda ação sensível: auditoria
- Toda entrada: validada com Zod
- Toda sessão: gerenciada corretamente

---

# 8. IA

- IA nunca tem acesso irrestrito
- Toda ação da IA registrada (prompt, contexto, output, decisão)
- Toda ação reversível quando possível
- Motor de regras determinísticas controla bloqueios críticos
- IA recomenda, humano decide em ações críticas
- Interface `LLMProvider` obrigatória desde o início

---

# 9. PROIBIÇÕES EXPLÍCITAS

- ❌ Introduzir dependência de um único fornecedor de IA
- ❌ Criar feature isolada sem considerar multi-tenant
- ❌ Alterar migration já aplicada em produção
- ❌ Sobrescrever `ProductTableVersion` ou comissão paga
- ❌ Confiar em validação de frontend para segurança
- ❌ Misturar conceitos de outros projetos
- ❌ Usar `DELETE` onde deve ser soft delete
- ❌ Fazer `git push --force` em `main`
- ❌ Commitar `.env` com segredos reais
- ❌ Rodar comandos destrutivos sem confirmar com o usuário

---

# 10. QUANDO EM DÚVIDA

Ordem de consulta:

1. Master v1.1
2. Current-state
3. DECISIONS.md
4. Este arquivo
5. **Perguntar ao usuário**

Nunca assumir.

---

# 11. SOBRE MÚLTIPLAS IAs

Este projeto pode ser trabalhado por várias IAs ao mesmo tempo:

- DeepSeek (chat)
- ChatGPT (chat)
- Claude (chat + Code)
- Gemini (chat + VS Code)
- Llama 3 (local no Continue)

**Regras para convivência:**

- Nenhuma IA sobrescreve decisão de outra sem registrar em `DECISIONS.md`
- Toda IA registra o que fez em `CHANGELOG.md`
- Toda IA atualiza `CURRENT-STATE.md` ao terminar
- Se houver conflito, o master vence
- Se o master for omisso, quem decidiu por último **deve documentar**

---

# 12. HANDOFF ENTRE IAs

Ao passar o projeto para outra IA:

1. Garantir que `master` e `current-state` estão no repositório e atualizados
2. Garantir que `CHANGELOG.md` reflete a última sessão
3. Garantir que `CURRENT-TASK.md` aponta para o próximo passo
4. Informar à nova IA: "leia master + current-state + rules antes de agir"

---

# FIM