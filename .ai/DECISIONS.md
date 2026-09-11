
**Regras:**
- ADRs aceitas NÃO são editadas — são substituídas por novas.
- Toda decisão arquitetural relevante deve virar um ADR.
- Se uma IA/sessão decide algo que afeta arquitetura, DEVE criar ADR.

---

# DECISÕES ACEITAS

## ADR-0001 — Uso de RLS para isolamento multi-tenant

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** O sistema é multi-tenant. Precisamos de isolamento forte entre organizações que não dependa apenas do backend.
- **Decisão:** RLS (Row Level Security) ativado em TODAS as tabelas de negócio, com policy baseada em `organization_id` extraído do JWT.
- **Alternativas:** isolamento apenas no backend (descartado — uma falha de código vaza dados); schemas separados por tenant (descartado — complexidade operacional).
- **Consequências:**
  - Backend nunca pode consultar sem tenant.
  - Testes por tenant são obrigatórios.
  - Performance exige índice em `organization_id`.
  - Toda nova tabela de negócio precisa de RLS desde a criação.

---

## ADR-0002 — Drizzle ORM como ORM/migrations

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** Precisamos versionar schema, ter SQL puro, integrar bem com RLS do Supabase e ter migrations reversíveis.
- **Decisão:** Usar **Drizzle ORM** para modelagem, queries e migrations.
- **Alternativas:**
  - Prisma (descartado — menos controle sobre SQL puro e RLS)
  - Supabase CLI apenas (descartado — sem tipagem forte automática, menos "código versionado")
  - SQL puro com `node-pg-migrate` (descartado — sem tipagem)
- **Consequências:**
  - Curva de aprendizado para quem só conhece Prisma.
  - Maior controle sobre SQL.
  - Migrations versionadas no repositório.
  - Tipos TypeScript gerados do schema.

---

## ADR-0003 — BullMQ + Redis como fila padrão

- **Data:** 11/09/2026
- **Status:** aceita (não implementada ainda)
- **Contexto:** Operações assíncronas são necessárias: WhatsApp, IA, importações, notificações, webhooks, conciliação.
- **Decisão:** Usar **BullMQ + Redis**.
- **Alternativas:**
  - `pg-boss` (Postgres puro) — aceitável como alternativa inicial se Redis não estiver disponível
  - AWS SQS / Google PubSub — descartado (dependência de cloud específica)
- **Consequências:**
  - Exige Redis na infraestrutura.
  - Workers separados do app Next.js.
  - Observabilidade de fila obrigatória.
  - Todo job deve aceitar `idempotency_key`.

---

## ADR-0004 — Separação `ProductTable` / `ProductTableVersion`

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** Tabelas de produto (taxas, coeficientes, comissões) mudam com o tempo. Precisamos manter histórico sem sobrescrever.
- **Decisão:** Separar identidade lógica (`ProductTable`) da versão imutável (`ProductTableVersion`).
- **Alternativas:** adicionar colunas de versão na mesma tabela (descartado — gera ambiguidade); apenas histórico em audit_logs (descartado — não modela vigência).
- **Consequências:**
  - Propostas referenciam `product_table_version_id`, não apenas o produto.
  - Nunca alterar uma versão publicada.
  - Para mudar regra, criar nova versão com `effective_from` posterior.

---

## ADR-0005 — Índice único de CPF por organização (parcial)

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** CPF deve ser único dentro do tenant, mas soft delete não deve bloquear recadastro. E CPF não pode ser único globalmente (LGPD + realidade de mercado).
- **Decisão:** Índice único **parcial** em `(organization_id, cpf)` com `WHERE deleted_at IS NULL`.
- **Alternativas:**
  - Unicidade global de CPF (descartado — viola LGPD e realidade)
  - Unicidade simples por tenant (descartado — bloqueia após soft delete)
  - Sem unicidade (descartado — permite duplicidade operacional)
- **Consequências:**
  - Sem unicidade global entre tenants.
  - Recadastro após soft delete é permitido.
  - Validação no backend + índice no banco.

---

## ADR-0006 — Imutabilidade de comissões pagas e audit_logs

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** Integridade financeira e rastreabilidade exigem que registros críticos não possam ser alterados.
- **Decisão:** Comissões pagas e `audit_logs` são **imutáveis** — sem UPDATE nem DELETE. Ajustes geram novo registro.
- **Alternativas:**
  - Permitir edição com log (descartado — abre brecha para fraude)
  - Arquivar em tabela separada (descartado — complexidade extra)
- **Consequências:**
  - Relatórios precisam considerar histórico completo.
  - Storage cresce monotonicamente.
  - Ajuste de comissão vira novo registro, nunca sobrescreve.

---

## ADR-0007 — Interface `LLMProvider` obrigatória

- **Data:** 11/09/2026
- **Status:** aceita (não implementada ainda)
- **Contexto:** O projeto não pode depender de um único fornecedor de IA. Diferentes sessões podem usar Gemini, Ollama, OpenAI, Anthropic, etc.
- **Decisão:** Criar abstração `LLMProvider` desde o início, mesmo que exista apenas um provider.
- **Alternativas:** acoplar diretamente a um SDK (descartado — refactor grande depois)
- **Consequências:**
  - Leve overhead inicial.
  - Trocar de IA não exige refactor grande.
  - Testes podem usar um provider falso.

---

## ADR-0008 — Nome do arquivo de estado

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** Evitar resquícios de outros projetos no documento master (o master v1.0 mencionava "AI-FACTORY" indevidamente).
- **Decisão:** O arquivo de estado atual chama-se **`CORBAN-CURRENT-STATE.md`**.
- **Alternativas:** `AI-FACTORY-CURRENT-STATE.md` (descartado — nome de outro projeto)
- **Consequências:** Consistência com a regra de "não misturar projetos".

---

## ADR-0009 — Estrutura oficial de pastas: `src/app/`

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** O repositório tem DUAS pastas `app/` concorrentes (raiz e dentro de `src/`). Isso cria ambiguidade de roteamento e confusão para IAs.
- **Decisão:** Manter **`src/app/`** como raiz do App Router. Apagar `app/` da raiz.
- **Alternativas:**
  - Manter `app/` na raiz (descartado — `src/lib/` já existe, coerência com `src/` é melhor)
  - Monorepo desde o início (descartado — complexidade prematura)
- **Consequências:**
  - Toda lógica vive dentro de `src/`.
  - `tsconfig.json` pode precisar ajuste de `baseUrl`/`paths`.
  - Toda IA deve respeitar essa estrutura.
- **Status de execução:** **pendente** — decisão tomada, execução não realizada.

---

## ADR-0010 — Modelo de trabalho com múltiplas IAs

- **Data:** 11/09/2026
- **Status:** aceita
- **Contexto:** O projeto pode ser trabalhado por DeepSeek, ChatGPT, Claude, Gemini e Llama local simultaneamente. Isso pode gerar conflito e perda de contexto.
- **Decisão:**
  - IA arquiteta (chat) decide, documenta, gera prompts.
  - IA executora (VS Code) executa, edita, commita.
  - Usuário é a ponte entre os dois.
  - Toda IA registra em `DECISIONS.md` e `CHANGELOG.md`.
  - Se houver conflito, o master vence.
- **Alternativas:** uma única IA para tudo (descartado — dependência de fornecedor); sem protocolo (descartado — caos).
- **Consequências:**
  - Handoff entre IAs é padronizado.
  - Documentação é obrigatória.
  - Nenhuma IA sobrescreve decisão de outra sem documentar.

---

# DECISÕES PENDENTES

| # | Pergunta | Recomendação | Prazo sugerido |
|---|---|---|---|
| P1 | Monorepo ou app único? | App único por ora; migrar quando surgir primeiro worker separado | Antes do primeiro worker |
| P2 | Supabase Auth ou Auth.js? | Supabase Auth (já instalado) | Fase 2 |
| P3 | Storage: Supabase puro ou S3-compatível? | Supabase Storage no início | Fase 7 |
| P4 | Provedor inicial de WhatsApp? | Meta Cloud API (gratuito até certo volume) | Fase 11 |
| P5 | Provedor inicial de assinatura eletrônica? | Clicksign (mais comum no Brasil) | Fase 8 |
| P6 | Hospedagem final: Vercel + Supabase ou VPS? | Vercel + Supabase no início | Fase 1 |
| P7 | Adicionar Gemini (grátis) no Continue para modo Agent? | Sim — Llama 3 local é limitado | Antes da limpeza de pastas |

---

# FIM