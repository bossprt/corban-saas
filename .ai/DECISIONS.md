
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

## ADR-0015 — Helper de RBAC como SECURITY INVOKER, definer só em schema privado, leitura financeira supervisor+
- **Data:** 19/09/2026
- **Status:** aceita; migrations correspondentes PREPARADAS, não aplicadas.
- **Decisão 1:** `has_active_organization_role` passa a SECURITY INVOKER (mesma assinatura). O definer era desnecessário: `organization_memberships` tem uma única policy (`select_self`) que não chama o helper e expõe exatamente as linhas que o helper lê. Remove o WARN do advisor sem tocar 36 policies e 10 funções.
- **Decisão 2:** quando um SECURITY DEFINER for inevitável (escrita em tabela sem policy de UPDATE), ele vive no schema não exposto `private` (PostgREST expõe só `public` e `graphql_public`, verificado), com `search_path=''`, sem argumento de organização e tenant derivado do recurso; a entrada pública é INVOKER. Caso atual: `private.attach_import_batch_adapter`.
- **Decisão 3:** dados de comissão/financeiro são legíveis apenas por supervisor+ no banco (RLS), não só na UI. Colunas de comissão em `proposal_commercial_snapshots` e `import_normalized_rows` exigem views por coluna (dívida B).
- **Decisão 4:** conflitos de importação são registrados de forma persistente, ligados às linhas raw imutáveis, idempotentes por fingerprint, sem poder publicar verdade financeira (`auto_publish_allowed=false` por CHECK).
- **Decisão 5:** o E2E rollback-only contra o schema live é o gate obrigatório antes de considerar uma cadeia de RPCs "funcional"; validação estrutural não basta (quatro RPCs live nunca funcionaram para usuário real).

## ADR-0016 — Segurança por coluna via readers privados, tenant ativo explícito, resolução imutável, leads como CRM
- **Data:** 20/09/2026 — **Status:** aceita; migrations `20260920_*` PREPARADAS, não aplicadas.
- **Decisão 1:** como `authenticated` é um único role de banco, colunas econômicas de tabelas mistas (`import_normalized_rows`, `proposal_commercial_snapshots`) saem do SELECT direto e são servidas por readers SECURITY DEFINER no schema `private` (membership + supervisor+ dentro), com wrappers INVOKER em `public`. Readers devem tratar role NULL como proibido (`coalesce(role,'')`).
- **Decisão 2:** o tenant ativo é explícito e determinístico: um membership → ele; vários → cookie `corban_org` re-validado contra memberships ativos a cada request; senão `/organizacao`. O client do app é escopado à organização ativa; RPCs derivam o tenant do recurso; RPCs sem recurso recebem `p_organization_id` validado.
- **Decisão 3:** catálogo comercial (`product_table_external_identities`) = manager+ em política e RPC.
- **Decisão 4:** a resolução de conciliação (nota/quem/quando) só muda junto da transição open→resolved, é carimbada pela sessão e é imutável; refresh não reabre caso resolvido.
- **Decisão 5:** Lead é registro de CRM com timeline append-only, sem colunas financeiras; escrita só por RPC; conversão atômica/idempotente; intake idempotente por (organização, canal, ref externa).
- **Decisão 6:** submissão externa passa por executor idempotente com ledger; providers externos ficam bloqueados por padrão; Bevicred permanece DEFERRED (recusa incondicional).

## ADR-0017 — Estado de integration_runs no banco, lease com fencing, evidência determinística, esteira só por RPC
- **Data:** 21/09/2026 — **Status:** aceita; migrations `20260921_*` PREPARADAS, não aplicadas.
- **Decisão 1:** a posse de um run é do BANCO, não de memória do worker: `claim_integration_run` serializa por `SELECT … FOR UPDATE` na identidade única (tenant, binding, fingerprint), concede lease + `claim_token` (fencing). Worker que perdeu o token não escreve mais nada; lease vencido permite takeover contando tentativa.
- **Decisão 2:** máquina de estados fail-closed em trigger (queued→running, running→running/succeeded/failed, failed→running só se não terminal e com tentativas, queued/failed→cancelled). `succeeded` exige artefato `response_metadata`; identidade do run é imutável; DELETE impossível; artefatos append-only e idempotentes por hash.
- **Decisão 3:** fencing por token e não por expiração: um worker lento e sozinho ainda registra o resultado real (evita segunda submissão ao provider). Revogação de membership bloqueia novo claim/retry/cancel, mas não descarta resultado em voo.
- **Decisão 4:** funções de worker são SECURITY INVOKER executáveis só por `service_role` (nenhum SECURITY DEFINER novo). Segredo em metadata/artefato/erro é rejeitado pelo banco e redigido antes pelo app (redactor determinístico e idempotente).
- **Decisão 5:** providers declaram `CapabilityManifest`; o executor consulta o manifest, nunca o nome do provider. Registro de providers guarda o estado de homologação; 2Tech = `awaiting_real_file`, Bevicred = `deferred`.
- **Decisão 6:** esteira (`operational_cases`, `operational_events`, `digitization_jobs`) só é escrita por RPC governada (token de guarda); eventos são append-only. Sucesso de provider é evidência de execução, nunca receita nem status pago.

## ADR-0018 — Worker server-only, dispatch consultivo, retry ≠ reexecução, escrita de proposta/timeline só por RPC
- **Data:** 22/09/2026 — **Status:** aceita; `20260922_worker_governance_v1` PREPARADA, não aplicada.
- **Decisão 1:** o worker é um ciclo limitado (`runDispatchCycle`, no máximo 25 itens, sem loop nem timer) acionado por algo externo (rota `POST /api/integrations/dispatch` com segredo Bearer, CLI ou fila). A rota fica DESABILITADA (503) enquanto `INTEGRATION_WORKER_SECRET` não existir e não é agendada em lugar nenhum.
- **Decisão 2:** `list_dispatchable_integration_runs` é consultivo; quem decide é `claim_integration_run` no banco (lease + fencing). O payload persistido em `metadata.request` é sempre redigido, então requests devem carregar REFERÊNCIAS (ids), nunca PII.
- **Decisão 3:** provider local/fake só resolve fora de produção E com `CORBAN_ALLOW_LOCAL_PROVIDERS=1`, e só se o manifest do adapter for idêntico ao do registro. Providers vêm do registro; nunca de `if provider===`.
- **Decisão 4:** RETRY continua a MESMA execução (governada pelo claim: espera, tentativas, lease). REEXECUÇÃO cria um run NOVO com `parent_run_id` + motivo obrigatório (10–500), fingerprint derivado do pai, idempotente por pai, manager+, só de pai terminal (falha terminal ou cancelado). Run concluído nunca é reexecutado; run retentável usa retry. O pai nunca é alterado.
- **Decisão 5:** `proposals_v2` e `customer_timeline_events` só são escritos por RPC governada (token transacional); identidade da proposta é imutável mesmo com o token; timeline é append-only inclusive para o owner. O trigger de proposta é nomeado para disparar antes dos guards antigos.
- **Decisão 6:** CORREÇÃO de regressão LIVE: `transition_operational_case` não setava o token da esteira exigido pelo hardening LIVE de 20260921 e falhava para todos os usuários; redefinida na nova migration.

## ADR-0019 — Despacho escopado por adapter, histórico de tentativas imutável, orçamento de tempo, replay idempotente de PAID
- **Data:** 23/09/2026 — **Status:** aceita; `20260923_worker_dispatch_hardening_v1` e `20260924_confirm_paid_replay_v1` PREPARADAS, não aplicadas.
- **Decisão 1:** o worker só pede ao banco runs de adapters que ele consegue executar (`p_adapter_keys`). Runs sem provider utilizável (2Tech sem arquivo, Bevicred, fake em produção) NÃO ocupam slots do ciclo. Ordenação por "momento em que ficou elegível" (`coalesce(next_attempt_at, lease_expires_at, created_at)`), sem prioridade inventada.
- **Decisão 2:** toda tentativa falha e todo lease expirado viram artefato `diagnostic` append-only (idempotente por tentativa). O retry limpa as colunas vivas de erro, mas o histórico nunca some. Mensagem de falha com cara de segredo vira marcador fixo e não trava mais o run.
- **Decisão 3:** um ciclo tem orçamento de relógio (`budgetMs`); não inicia run novo se não couber um timeout de provider. Defaults serverless: timeout 20s, lease 60s, orçamento 45s, `maxDuration` 60s. O que sobra fica elegível no próximo ciclo.
- **Decisão 4:** o fake local só resolve com `NODE_ENV` em {development,test} E `CORBAN_ALLOW_LOCAL_PROVIDERS=1` (allow-list; NODE_ENV ausente/desconhecido não basta).
- **Decisão 5:** o endpoint de dispatch é uma função pura (`handleDispatchRequest`): 503 sem segredo forte, 403 para credencial errada/malformada, corpo só com contagens; esquema Bearer case-insensitive, credencial exata.
- **Decisão 6:** replay de `confirm_proposal_paid_from_import` devolve a mesma evidência (idempotente) em vez de errar com `proposal_must_be_approved`.

## ADR-0020 - Governed team access lifecycle (invitations, role/status changes, admin audit)
- **Data:** 24/09/2026 - **Status:** aceita; `20260925_team_access_lifecycle_v1` PREPARADA, NAO aplicada.
- **Decisao 1:** identidade continua sendo Supabase Auth + `organization_memberships`. Nao existe segundo sistema de identidade nem token de convite proprio: o e-mail/link e emitido e verificado pelo Auth.
- **Decisao 2:** toda escrita de membership/convite/auditoria passa por RPC SECURITY INVOKER + guard trigger (`corban.membership_rpc`). O authenticated perde INSERT/DELETE em memberships e so atualiza `role,status,updated_at`. Nenhuma funcao SECURITY DEFINER nova (baseline 8 mantido).
- **Decisao 3 (politica):** admin gerencia todos; gerente so supervisor/agente (no perfil atual E no novo); ninguem altera o proprio acesso; supervisor/agente nada. Perder o ultimo admin e estruturalmente impossivel (so admin toca admin, nunca a si mesmo).
- **Decisao 4:** aceite de convite e service_role-only, usa a identidade validada pelo Auth (`getUser`, `email_confirmed_at`). Convite nunca altera silenciosamente o perfil de um membro ativo; membro desativado e reativado com o perfil do convite (resultado explicito).
- **Decisao 5:** auditoria append-only (`organization_admin_events`), sem token/senha/segredo. Limite de 20 convites/hora/ator no banco.
- **Decisao 6:** visibilidade de comissao continua fail-closed (supervisor+) e centralizada em `canViewCommission`; a decisao comercial sobre o agente segue PENDENTE do Owner (ver gap analysis).
- **Decisao 7:** `/api/health` publico so devolve app+banco; prontidao de worker/provedor e visivel apenas a supervisores logados. Providers locais sempre rotulados `LOCAL / TESTE`.

## ADR-0021 - Governed simulation writes and merged membership SELECT policy
- **Data:** 24/09/2026 - **Status:** aceita; `20260926_simulation_governance_v1` e `20260927_membership_select_policy_merge_v1` PREPARADAS, nao aplicadas.
- **Decisao 1:** simulacoes so nascem por `create_simulation` (INVOKER): tenant derivado do cliente, tabela publicada do MESMO tenant, taxa/coeficiente da versao, parcela calculada no banco, ator = auth.uid(). Escrita direta (INSERT/UPDATE/DELETE) fica recusada por guard trigger + grants por coluna.
- **Decisao 2:** `expected_commission_amount` e `released_amount` de simulacoes ficam NULL: nao existe fonte governada, portanto nada pode forja-los. Metadata da tabela nao e copiada para snapshots.
- **Decisao 3:** a acao do app mantem um fallback TEMPORARIO (insert calculado no servidor) apenas quando o PostgREST informa que a RPC nao existe; depois da migration o banco recusa esse insert. Remover apos aplicar.
- **Decisao 4:** duas policies permissivas de SELECT em `organization_memberships` viram uma so (mesma logica OR), para limpar o warning do advisor de performance sem mudar visibilidade.
- **Decisao 5:** recuperacao de senha usa Supabase Auth com resposta identica para qualquer e-mail; a politica de senha final e do Auth (runbook).

## ADR-0022 - Operator feedback through whitelisted redirect codes; revoked-actor runs leave the dispatch list
- **Data:** 25/09/2026 - **Status:** aceita; `20260928_revoked_actor_dispatch_v1` PREPARADA, nao aplicada.
- **Decisao 1:** em producao o Next.js esconde a mensagem de `Error` lancado por server action; por isso as acoes do fluxo do operador redirecionam com um codigo (`?f=ok:...|erro:...`) e o shell mostra texto fixo de uma lista branca. Texto arbitrario na URL nunca e renderizado. Erros do banco viram codigo, nunca texto.
- **Decisao 2:** uploads: o tipo aceito e o dos primeiros bytes (PDF/JPEG/PNG/WebP) e precisa coincidir com o declarado; tamanho, vazio e nome sao verificados antes de tocar banco/Storage.
- **Decisao 3:** run cujo criador perdeu acesso sai da lista de dispatch (mesma regra do `claim`) e e encerrado por `sweep_orphaned_integration_runs` (service_role): queued/retry -> cancelled, running vencido -> failed terminal, codigo fixo sanitizado. O worker chama o sweep antes de listar, best effort.
- **Decisao 4:** menu por perfil e dashboard do operador limitado aos proprios registros sao conveniencia de UX; a autorizacao continua no banco.

## ADR-0023 - Catalog publication through governed RPCs; platform-owned reference catalog; Vercel-safe uploads
- **Data:** 25/09/2026 - **Status:** aceita; `20260929_catalog_publish_v1` PREPARADA, nao aplicada.
- **Decisao 1:** publicar versao de tabela e checklist so pelas RPCs `publish_product_table_version` (admin/gerente) e `publish_document_checklist_template` (supervisor+), INVOKER, com guard trigger (GUC `corban.catalog_rpc`). INSERT de authenticated e sempre rascunho; publicar substitui a versao anterior na mesma transacao; publicada continua imutavel.
- **Decisao 2:** o catalogo de referencia global e da PLATAFORMA: escrito apenas pela rota `/api/admin/reference-catalog` (administrador de plataforma, upsert idempotente por codigo, auditado, sem dado inventado). Tenants montam rotas/tabelas/checklists sobre ele.
- **Decisao 3:** etapas padrao da esteira (7 estados, sem `paid`, sem SLA) sao dominio, nao dado comercial; criadas sob demanda por gerente/admin.
- **Decisao 4:** bootstrap de organizacao exige CNPJ valido (guardado so com digitos), recusa duplicata e pede confirmacao explicita para nome parecido; id do tenant vem do banco.
- **Decisao 5:** upload de documento limitado a 4 MB (limite de corpo da Vercel); upload direto ao Storage fica como P1. Origem publica: `NEXT_PUBLIC_SITE_URL` obrigatoria em producao; fallback so para mesma origem.

## ADR-0024 - Commercial Model V3: catalogo comercial do tenant, condicao unica e grupos de comissao dinamicos
- **Data:** 26/09/2026 - **Status:** aceita; `20261002_commercial_model_v3_foundation_v1` PREPARADA, testada rollback-only (100 checks ALL PASS), NAO aplicada (Human Gate).
- **Decisao 1:** aditivo e compativel: tabelas novas do tenant (`organization_banks/providers/agreements`, `commission_groups`) ao lado das globais legadas; `organization_product_routes` ganha o formato V3 (banco + convenio + provedor opcional) por CHECK exclusivo, sem renome nem drop. Historico intacto.
- **Decisao 2:** Tipo de Contrato (`contract_types`) e estrutura GLOBAL somente leitura, sem produto/banco/tenant. Convenios nacionais (27 governos incl. DF + 26 prefeituras de capitais) sao templates globais sem banco; o tenant os habilita e o banco força o nome oficial. Produto operacional = tabela comercial do tenant.
- **Decisao 3:** condicao comercial = uma linha por versao/Tipo de Contrato/prazo com coeficiente e/ou taxa (lidos por todo membro, a simulacao precisa) e, separados e supervisor+, comissao recebida e uma participacao por grupo, gravados numa unica RPC `save_commercial_condition` (INVOKER, guard-token). Versao publicada congela suas condicoes.
- **Decisao 4:** grupos sao regras dinamicas do tenant com `calculation_basis` explicito (`percent_of_production` | `percent_of_received_commission`); cada base e validada isoladamente e nunca somada a outra. Comissao recebida e repasse continuam conceitos separados; gerente/supervisor sao grupos opcionais.
- **Decisao 5:** dinheiro/percentual so NUMERIC no banco e string decimal canonica + BigInt escalado no app; nunca Float. Codigos tecnicos sao gerados pelo banco/servidor e nunca digitados nem exibidos.
- **Decisao 6:** importacao CSV/XLSX admite uma coluna por grupo; coluna desconhecida, duplicada ou ambigua RECUSA o arquivo inteiro; celula vazia = grupo fora da condicao (nao zero). Salvamento linha a linha pela mesma RPC, idempotente.
- **Decisao 7:** comissao continua fail-closed (supervisor+); simulacao por condicao (`create_simulation_for_condition`) nunca copia comissao. Integracao dos grupos com snapshot/split/repasse fica para a proxima onda.
