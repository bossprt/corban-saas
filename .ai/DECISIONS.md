
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

---

## ADR-0011 — Membership explícito e contexto tenant fail-closed

- **Data:** 17/09/2026
- **Status:** aceita; substitui a parte do ADR-0001 que dependia de `organization_id` no JWT como fonte única de tenant.
- **Contexto:** O banco vivo usa `profiles.organization_id` e `get_user_organization_id()`. Isso suporta apenas um vínculo simples por usuário e não é suficiente para a evolução V2 de RBAC, múltiplas organizações e revogação contextual.
- **Decisão:** Introduzir `organization_memberships` como vínculo explícito entre usuário e organização. O tenant efetivo deve ser resolvido de forma fail-closed a partir de sessão autenticada + membership ativo/autorizado. Claims/JWT podem otimizar contexto, mas não substituem a validação vigente no backend/banco.
- **Migração:** aditiva primeiro; preservar `profiles.organization_id` durante transição e migrar memberships existentes de forma idempotente. Nenhuma remoção do legado até testes de isolamento e compatibilidade passarem.
- **Segurança:** policies V2 serão explícitas por operação; inserts/updates exigirão `WITH CHECK` coerente. Relações tenant-scoped críticas devem impedir referência cruzada entre organizações.
- **Consequências:** um usuário poderá futuramente participar de mais de uma organização; revogação de membership passa a ser fonte operacional; testes A/B entre tenants tornam-se gate obrigatório; código não pode confiar apenas em tenant enviado pelo cliente.


---

## ADR-0012 — Identidade canônica, canais comerciais e rede de distribuição

- **Data:** 18/09/2026
- **Status:** aceita conceitualmente; substitui a linearidade `Bank → Provider/Master → ...` da seção 6 do Master V2.
- **Evidência operacional:** Smart pode operar o mesmo banco/tabela simultaneamente como Sub e via Correspondentes parceiros (ex.: Efetiva Mais/Bevicred), com comissões diferentes. A Smart também pode ser Master e possuir Subs abaixo dela.
- **Decisão:** Banco/tabela são identidades canônicas independentes do canal. Master, Subestabelecido e Parceiro são papéis da relação comercial, não tipos permanentes da empresa. Uma organização pode ocupar papéis diferentes simultaneamente, inclusive para o mesmo banco.
- **Identidade:** Proposal possui UUID interno imutável. Identidades externas são vinculadas separadamente; número de proposta bancária é match forte, preservando instituição+numero como chave externa defensiva. Tabelas também possuem identidade canônica e aliases/códigos por canal.
- **Canal:** cada canal registra contraparte, papel, códigos/nomenclaturas externas, vigência e condições comerciais. A mesma tabela pode ter múltiplos canais concorrentes.
- **Rede:** tenant pode vender para organizações acima e receber produção de organizações abaixo. CNPJ/identificadores da rede determinam o produtor econômico quando relatórios externos consolidam Subs.
- **Financeiro:** separar produção, comissão gerada, direito econômico, pagador, recebido e divergência. Split de Sub pode ser 100/0, 95/5, 90/10 etc. por regra/versionamento, inclusive por componente.
- **Componentes:** à vista, diferido, antecipação do diferido, bônus/campanha e outros componentes são separados. Antecipação converte o diferido conforme fator vigente; não soma o percentual nominal do diferido como receita imediata.
- **Histórico:** proposta congela rota, identidades externas e regras financeiras vigentes. Alterações futuras não recalculam proposta histórica.
- **Conciliação:** matching determinístico por identidade externa forte; ambiguidades exigem Human Gate. Pagamento direto do banco ao Sub não transforma comissão do Sub em receita da Master; somente a participação econômica da Master e bônus elegíveis entram como receita esperada da Master.

## ADR-0013 — Adapter 2Tech, contrato canônico de observação e fail-closed de reversões
- **Data:** 18/09/2026
- **Status:** aceita.
- **Decisão 1 (adapter):** `2tech/busca_contrato_file` (contrato 1.0.0) trata 2Tech como *provider* e a instituição financeira como dimensão separada, lida apenas de coluna explícita. `StatusBancoCliente`, `StatusEmpresaVendedor` e `StatusProposta` permanecem independentes; nenhum texto de status vira estado canônico. Comissão em branco (`not_reported`) é distinta de zero (`reported_zero`) e nenhuma das duas significa ausência de receita. Semântica financeira do adapter é `production_report`: não afirma comissão nem pagamento.
- **Decisão 2 (schema):** impressão digital dos cabeçalhos; schema sem coluna de identidade de proposta ou sem coluna de semântica conhecida é colocado em quarentena (linhas `record_kind='other'`, sem número de proposta). Impressões conhecidas só são registradas após validação com arquivo real; até lá todo schema é `unverified`.
- **Decisão 3 (canônico/conflitos):** códigos de provider são aliases (`canonical.ts`), nunca enums. Identidade de proposta = instituição + número, independente do provider. `conflicts.ts` detecta replay, duplicata no lote, múltiplas fontes, status contraditório, correção posterior, identidade ambígua e linhas de tenants distintos (bloqueio); `autoPublishAllowed` é sempre `false`.
- **Decisão 4 (achados de revisão adversarial no banco live, corrigidos apenas em migrations preparadas):** (a) `refresh_financial_reconciliation` somava reversões (valores são >= 0) em vez de subtrair; (b) eventos `reversal`/`adjustment` podiam ser inseridos diretamente sem validar organização/proposta/componente/valor; (c) `authenticated` tinha TRUNCATE/REFERENCES/TRIGGER em quase todas as tabelas de tenant, o que ignora RLS e triggers de imutabilidade. Correções em `20260919_*`, aguardando Human Gate.
- **Consequência:** nada de `20260919_*` está aplicado no Supabase remoto.

## ADR-0014 — Ledger append-only com reversões parciais, tenant derivado do recurso e blockers live
- **Data:** 19/09/2026
- **Status:** aceita; migrations correspondentes PREPARADAS, não aplicadas (Human Gate).
- **Decisão 1:** reversão é evento compensatório; várias reversões parciais do mesmo evento são válidas e o total acumulado não pode exceder o original. Não existe UNIQUE por `reverses_event_id`. Concorrência: advisory lock por evento original antes de ler a soma (RPC e trigger); isolamento diferente de READ COMMITTED é rejeitado.
- **Decisão 2:** todo tipo de evento financeiro só entra por publisher governado; `adjustment` e tipos sem publisher permanecem bloqueados.
- **Decisão 3:** o tenant de uma operação é derivado do recurso (evento, proposta, lote) e só depois se exige membership ativo naquele tenant; nunca `organization_memberships ... limit 1`. Classificação completa em `docs/audits/AUDIT-2026-09-19-TENANT-RESOLUTION-AND-LIVE-BLOCKERS.md`.
- **Decisão 4:** `financial_reconciliation_cases` só recebe valores derivados via `refresh_financial_reconciliation`; humanos apenas resolvem casos com nota.
- **Decisão 5:** `attach_import_batch_adapter` é SECURITY DEFINER estreito (única forma de gravar linhagem de adapter) porque `import_batches` não tem policy de UPDATE.
- **Achados live (A):** `has_active_organization_role` sem EXECUTE para `authenticated` (todas as escritas com RBAC falham) e `digest()` não qualificado sob `search_path=public` (ingestão e publisher de evidência falham).
