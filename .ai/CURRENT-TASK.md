# CURRENT TASK — CORBAN OS V2

**Atualização:** 18/09/2026
**Branch:** `architecture/corban-os-master-v2`

## Concluído
- Operational State Machine V0 + RBAC Hardening V0 live e contratos aprovados.
- Mesa operacional conectada à RPC transacional.
- ADR-0012 registrado: identidade canônica de proposta/tabela, múltiplos canais para o mesmo banco/tabela, rede Master/Sub/Parceiro, pagador independente, split versionado e componentes de comissão.
- Evidências reais analisadas: Daycoval Governo do Acre, Efetiva Mais/2tech e Bevicred. Confirmam códigos/nomenclaturas de canal distintos e remuneração variável para a mesma origem bancária.
- Migration `20260918_commercial_network_channels_v0.sql` preparada, NÃO aplicada.
- Contract `tests/security/commercial-network-channels-contract.sql` preparado.

## Modelo preparado
- commercial_entities
- commercial_relationships
- commercial_channels
- product_table_external_identities
- channel_commission_rule_versions
- commission_rule_components
- network_split_rule_versions
- proposal_external_identities
- proposal_commercial_snapshots

## Invariantes
- UUID Corban é identidade técnica canônica da proposta.
- Número externo da proposta é identidade forte, armazenada defensivamente como instituição + número.
- CNPJ/identidade da rede identifica produtor/Sub; não substitui identidade da proposta.
- Banco/tabela não são duplicados por canal.
- Master/Sub/Parceiro são papéis da relação, não classificação permanente da empresa.
- Split 100/0, 95/5, 90/10 etc. é versionado e pode variar por banco/tabela/componente.
- Comissão à vista, diferido, antecipação, bônus/campanha são componentes distintos.
- Produção, direito econômico, pagador, recebido e divergência são fatos distintos.
- Proposal congela rota e regras vigentes.

## Estado live após autorização
- `commercial_network_channels_v0` aplicado com sucesso.
- Contract executado sem exceções.
- Security advisor: 0 ERROR; permanece somente WARN de leaked-password protection e 2 INFO intencionais de platform tables.
- Performance advisor apontou FKs sem índice; patch `commercial_network_indexes_v0` aplicado dentro do hardening do escopo autorizado.
- Workspace `/app/rede` criado e navegação adicionada; nenhum dado comercial foi inventado.

## Próximo passo
1. Validar Preview Vercel do workspace de Rede.
2. Preparar Import Staging/Lineage para Daycoval, Efetiva Mais e Bevicred.
3. Construir configuração de entidades/relações/canais e regras em modo draft.
4. Publicação de regra financeira real continuará exigindo evidência determinística da fonte e validação apropriada.


## Execução autônoma seguinte
- Preview anterior da Rede validado com Vercel SUCCESS.
- Preparado `20260918_import_staging_lineage_v0.sql`: fonte → lote/hash → raw imutável → normalização versionada → candidatos de matching → decisão humana.
- Contract de segurança preparado.
- Workspace `/app/importacoes` e navegação adicionados; funciona fail-closed enquanto o schema não estiver live.
- Nenhum arquivo comercial foi importado/publicado e nenhum dado financeiro foi inferido.

## Human Gate atual — novo DDL
A próxima ação necessária é aplicar `20260918_import_staging_lineage_v0.sql` no Supabase de produção. É novo DDL e não está coberto pelas autorizações anteriores.


## Import Staging live
- Autorização recebida e `import_staging_lineage_v0` aplicada live com sucesso.
- Contract pós-apply passou sem exceções.
- Security advisor: 0 ERROR; apenas leaked-password WARN e 2 INFO intencionais de platform admin.
- Performance hardening de FKs do módulo de importação aplicado como `import_staging_indexes_v0`.
- Contrato documental de adapters criado em `docs/imports/IMPORT-ADAPTER-CONTRACT-V0.md`.
- Contrato TypeScript determinístico criado em `src/lib/imports/contract.ts`.
- Adapters iniciais Daycoval, Efetiva Mais e Bevicred criados em `src/lib/imports/adapters.ts`.
- Nenhuma publicação/importação de dados comerciais reais executada automaticamente.


## Continuação autônoma — UI e Import Engine
- Preview anterior validado com Vercel SUCCESS.
- Rede Comercial agora possui ações server-side com dupla proteção: papel admin/manager no app + RLS no banco.
- UI permite cadastrar entidade, relação e canal sem assumir que Master/Sub/Parceiro é tipo fixo da empresa.
- Nenhum seed comercial foi criado: banco/entidade/canal real continua vindo de evidência ou cadastro autorizado.
- Import Engine ganhou seleção explícita de adapter, SHA-256, validação determinística de linhas e chave de identidade de proposta.
- Preview dos últimos commits foi disparado; aguarda status.
- Próxima implementação sem DDL: tela de detalhe/revisão dos lotes e matching. Upload/ingestão real exige arquivo acessível ao runtime e fonte escolhida; publicação de mapping/regra financeira permanece separada.


## Matching review
- Preview da tela de lote anterior validado com Vercel SUCCESS.
- Revisão de candidatos agora registra decisão append-only em `import_decisions`, auditada pelo usuário autenticado.
- Perfis admin/manager/supervisor podem aprovar/rejeitar/marcar revisão; candidato ambíguo é bloqueado para aprovação direta.
- Matcher canônico fail-closed criado: número externo + instituição resolve proposta quando único; código externo de tabela resolve alias quando único; colisão ou ausência vira Human Gate.
- Nenhuma decisão altera proposta, catálogo ou financeiro automaticamente.


## Reconciliation visibility
- Matching-review Preview validado com Vercel SUCCESS.
- Lista de importações agora mostra prontidão: linhas normalizadas, matches fortes e revisões humanas por lote.
- Detalhe da proposta agora expõe identidades externas reconciliadas e snapshot de rota comercial quando existirem.
- Documento `RECONCILIATION-ENGINE-V0.md` fixa prioridade de identidade e separa decisão de matching de mutação de catálogo/proposta/financeiro.
- Próxima fronteira de domínio: aplicar decisão aprovada de forma transacional e idempotente. Isso exigirá RPC/DDL novo para garantir atomicidade e lineage, portanto deve ser preparado antes do próximo Human Gate.


## Approved match application live
- `apply_approved_import_match_v0` aplicado no Supabase com sucesso após autorização explícita.
- Contract live passou: RPC existe, anon sem EXECUTE, authenticated com EXECUTE e lineage protegido por RLS.
- Security advisor permanece 0 ERROR; WARN conhecido apenas para leaked-password protection.
- UI agora separa claramente: sugerir match → registrar decisão → aplicar vínculo aprovado.
- Aplicação é idempotente e cria somente identidade externa de proposta/alias de tabela; não publica comissão, pagamento ou receita.
- Preview do fluxo atualizado disparado na Vercel.


## Adversarial commercial-network hardening prepared
- Vercel baseline `b9b5cbd` confirmed SUCCESS after prior failed historical commits.
- Adversarial review confirmed a remaining integrity gap: tenant RLS restricted row visibility but simple UUID FKs could still reference another tenant if an ID became known.
- Prepared `20260918_commercial_network_integrity_hardening_v0.sql` to enforce same-organization references across commercial relationships/channels/table aliases/proposal identities/snapshots/rules.
- Same migration freezes already-published commission and network split rule versions against update/delete.
- Security contract prepared; migration NOT applied because it is new production DDL.


## Commercial integrity hardening live
- Autorização recebida e `commercial_network_integrity_hardening_v0` aplicada com sucesso.
- Contract pós-apply passou sem exceções.
- Security advisor: 0 ERROR; permanecem apenas 2 INFO intencionais de Platform Admin e WARN de leaked-password protection.
- Same-organization guards agora protegem referências da rede comercial; regras de comissão/split publicadas ficam imutáveis.
- Próxima frente preparada sem DDL: `FINANCIAL-TRUTH-LEDGER-V0.md` e workspace `/app/financeiro`.
- Workspace financeiro é deliberadamente read-only/readiness: não calcula nem publica receita enquanto ledger append-only não estiver autorizado.
- Preview Vercel do novo workspace disparado.


## Financial Truth Ledger prepared — Human Gate
- Vercel commits `5c70b393` e `0007e6da` confirmados SUCCESS.
- Preparado `20260918_financial_truth_ledger_v0.sql`: eventos financeiros append-only, evidence lineage e casos de reconciliação expected/reported/settled.
- Idempotency por tenant, reversão por evento compensatório, valores numeric, nenhum UPDATE/DELETE autenticado sobre histórico financeiro.
- Contract de segurança preparado.
- Migration NÃO aplicada: novo DDL financeiro de produção exige autorização explícita.


## Financial ledger live + import hardening
- Financial Truth Ledger V0 confirmed live; finance dashboard now reads live event/reconciliation counts.
- Corrective hardening applied to `apply_approved_import_match`: superseded approvals cannot be applied; candidate/decision/normalized-row lineage must agree; proposal/table/channel tenant consistency is checked; an existing external identity pointing to a different canonical target now fails closed.
- Authenticated retains RPC EXECUTE; anon does not.
- Performance advisor initially found 10 uncovered FKs + 1 RLS init-plan warning. Corrective patch applied; recheck now has no unindexed-FK or auth-RLS warnings, only unused-index INFO (expected on a new/empty system) and Auth connection-strategy INFO.
- Vercel `f876e730` SUCCESS.


## Expected commission publisher prepared — Human Gate
- Prepared `20260918_expected_commission_publisher_v0.sql` and contract.
- Publisher is deterministic and SECURITY INVOKER: requires supervisor+ role, frozen proposal commercial snapshot, published commission rule, published split when present, and explicit `calculation_base_amount` frozen in snapshot.
- Publishes only `commission_expected`, never `payment_received`.
- Component calculation supports fixed/percentage and deferred anticipation factor; tenant entitlement applies frozen upstream split when component-compatible.
- Idempotency key prevents repeated publication for the same proposal/rule/component/split.
- No production apply performed: this function creates financial facts and is therefore a new financial-publication DDL Human Gate.


## Expected commission publisher live
- Autorização recebida; `expected_commission_publisher_v0` aplicada com sucesso.
- Runtime contract: SECURITY INVOKER confirmado, authenticated EXECUTE=true, anon EXECUTE=false.
- Security Advisor permanece 0 ERROR; WARN conhecido de leaked-password protection continua.
- Proposal detail agora possui ação supervisor+ para publicar comissão esperada e lista fatos financeiros da proposta.
- UI deixa explícito que comissão esperada não significa recebida.
- Preview do commit `9ee01ffa` disparado.


## Evidence-backed financial reconciliation prepared — Human Gate
- Vercel `9ee01ffa` and `60807908` confirmed SUCCESS.
- Prepared `20260918_financial_reconciliation_publisher_v0.sql` + contract.
- Evidence publisher accepts only commission_reported/payment_received/downstream_paid and requires bank/partner/import/payment/manual-review evidence; proposal matching alone cannot create settlement.
- Idempotency combines event/proposal/component/source/reference.
- Reconciliation refresh deterministically aggregates expected vs reported vs received and classifies open/matched/divergent/human_required.
- Migration NOT applied because it introduces new financial publication RPCs.


## Evidence-backed reconciliation live
- Authorized `financial_reconciliation_publisher_v0` applied successfully.
- Runtime verified both RPCs SECURITY INVOKER, authenticated EXECUTE=true, anon=false.
- Finance workspace now exposes expected / reported / received / divergence cases.
- Proposal server action can refresh deterministic reconciliation for a component.
- No bank/partner report has been ingested and no received revenue has been fabricated.
- Next integration boundary: turn approved import evidence into reported/settled financial events only when the source semantics explicitly prove the corresponding financial fact.


## Reconciliation preview repaired + financial import semantics
- Detected Vercel failure on `d2444db`; root cause in repository was malformed JSX in `/app/financeiro`.
- Fixed in `db9ffb60`; Vercel confirmed SUCCESS.
- Added `IMPORT-FINANCIAL-SEMANTICS-V0.md` defining source classes and fail-closed publication rules.
- Known Daycoval Gov Acre, Efetiva Mais table evidence and Bevicred table evidence remain commercial_offer evidence only; they cannot publish payment_received.
- No real financial rows inserted.


## Import financial semantics enforced in code — next DDL gate
- Known adapters now carry explicit `financialSemantic`; Daycoval/Efetiva/Bevicred table adapters are `commercial_offer`.
- Engine fail-closes financial publication unless source semantics are commission_statement/payment_statement/network_payment_statement.
- Batch review UI surfaces the semantic class and explicitly states commercial_offer does not publish receipt.
- Prepared `20260918_import_source_financial_semantics_v0.sql` to persist source semantics and freeze semantic reinterpretation after a source has batches.
- Migration NOT applied: new production DDL requires explicit authorization.


## Import source financial semantics live
- Authorized `import_source_financial_semantics_v0` applied successfully.
- Runtime verified semantic columns exist with default `commercial_offer`; freeze trigger helper is not executable by authenticated/anon.
- Security Advisor remains 0 ERROR; known leaked-password WARN persists.
- Added governed source registry to `/app/importacoes`: admin/manager can create source + explicit financial semantic, with reviewer/timestamp recorded.
- Existing source semantics become immutable once batches reference the source.
- No real source records or financial facts were fabricated by the assistant.
- Preview for source registry triggered.


## Autonomous MVP acceleration — external deployment gate reached
- User pre-authorized all migrations/changes following triple-review + adversarial pattern until an external configuration is required.
- Applied `atomic_import_ingestion_v0`: atomic, tenant-scoped, SHA-256-idempotent ingestion of normalized batches; SECURITY INVOKER, authenticated only.
- Added dependency-free CSV + HTML-XLS parsing and governed upload UI. XLSX deliberately fails closed pending a homologated binary parser.
- Applied `commercial_rule_management_rpc_v0`: admin/manager atomic publication of immutable commission rules and split versions; UI added in `/app/rede`.
- Dashboard now includes expected commission, proven receipts, financial divergences and human-review signals.
- Review 1 (completeness) found/fixed canonical column mismatches: import_sources.is_active and product_tables.status.
- Review 2 (adversarial) found/fixed reviewer identity bug: source semantic reviewer now uses authenticated user.id, not a non-selected membership field.
- Review 3 database/runtime: new RPCs confirmed SECURITY INVOKER, authenticated EXECUTE=true, anon=false; Security Advisor 0 ERROR. Known leaked-password WARN remains.
- Deployment validation is externally blocked: Vercel Hobby build-rate limit returns upgradeToPro=build-rate-limit for current commits. This is not a project build error and cannot be changed from current connected tools.

- Vercel plan was upgraded by the owner on 2026-09-18; trigger a fresh preview commit because prior commit status remains the historical Hobby rate-limit failure.


## Post-upgrade continuous execution
- Vercel plan upgrade removed Hobby build-rate-limit; fresh previews now start normally.
- Continued adversarial finance hardening: `financial_truth_write_path_hardening_v0`, `financial_rpc_advisor_hardening_v0`, and `financial_truth_guard_trigger_v0` applied live.
- Financial reported/received/downstream-paid facts now require governed evidence RPC; direct INSERT path is blocked by trigger defense-in-depth.
- Import evidence semantics enforced live: commercial_offer cannot prove commission/payment; import raw-row/decision lineage must match batch.
- Reconciliation identity is unique per proposal/component; zero-evidence expected commissions remain open rather than false divergent.
- Financial RPCs verified SECURITY INVOKER, authenticated only; trigger helper not executable; Security Advisor 0 ERROR. Known leaked-password protection WARN remains external configuration.
- Finance UI links reconciliation to proposal and formats BRL.
- Daycoval CSV fallback enabled while XLSX remains fail-closed until binary parser homologation.
- Current Vercel build failures are now actual project builds (not rate limit); simplified JSX expressions and triggered preview at HEAD for diagnosis.


## Triple-review continuation
- Review pass 1: removed remaining nullish-coalescing expressions embedded in JSX array literals in Network/Finance summaries to isolate parser/build regressions.
- Review pass 2: verified governed finance actions and live DB guards; financial evidence trigger remains live and Security Advisor remains 0 ERROR.
- Review pass 3: attempted proposal reconciliation UI; preview failed, so the UI delta was rolled back while keeping the already-existing server action and live reconciliation RPC intact. No broken preview change was accepted as complete.
- Vercel continues to return project-build failures, but connected Vercel identity exposes no team/project logs. GitHub status provides only failure URL, not compiler output.
- Current external blocker: exact Vercel compiler/build log is inaccessible to available tools; further blind changes would violate the adversarial/review rule.


## Build typecheck correction
- Vercel compiler log supplied by owner identified TS2322 in `/app/importacoes`: form server action returned `{batchId}`.
- Corrected `ingestImportFile` to return `Promise<void>`; second review removed now-unused RPC return binding.
- Previous compiler phase had already confirmed webpack compilation success; failure was TypeScript-only.
- Triggering a clean preview from documented HEAD because GitHub had not attached a Vercel status to the correction commits.


## Preview restored after TypeScript correction
- Owner-provided Vercel screen confirms deployment FqTD5cVf7 for commit 2466f0c is Ready/Latest on Preview after 36s.
- Login surface rendered in deployment preview; server-action TS2322 is resolved.
- GitHub status lagged as pending at verification time, but Vercel UI is authoritative for this deployment and shows Ready.
- Resume remaining MVP implementation from green preview baseline; do not modify main.


## MVP closure wave — pre-authorized autonomous execution
- Deterministic import matching RPC live: exact proposal identity > strong table alias > ambiguous/none human review; suggestions never mutate canonical truth.
- Ingestion now runs matching automatically after atomic batch creation.
- Added governed generic CSV adapters for commission statements, received-payment statements and network-payment statements; adapter semantic must exactly match immutable source semantic.
- Approved+applied exact import decisions can publish financial facts through a guarded RPC; publication auto-refreshes reconciliation. Commercial-offer evidence remains blocked.
- Added per-component proposal commercial snapshots so upfront/deferred/anticipated/bonus splits can differ. Route freeze selects published split by relationship/bank/table/component specificity and freezes it.
- Hardened commercial snapshot writes with trigger defense-in-depth: authenticated clients cannot bypass the freeze RPC.
- Added native XLSX parsing with ExcelJS 4.4.0; CSV and legacy HTML-XLS remain supported.
- Review 1 completeness: fixed missing automatic matching and source semantic equality.
- Review 2 adversarial: identified and closed direct commercial snapshot insert bypass; financial facts still require approved+applied exact identity plus evidence semantics/date/amount.
- Review 3 runtime: new RPCs are SECURITY INVOKER, authenticated-only; Security Advisor remains 0 ERROR. Performance Advisor found 3 new uncovered FKs; covering indexes applied.
- No financial or commercial production facts were fabricated; new snapshot table currently has zero rows.
- Trigger fresh Vercel preview to typecheck the full closure wave.


## Operational evidence + native XLSX closure
- Added native XLSX server parser via ExcelJS 4.4.0; Daycoval/Efetiva adapters can consume XLSX after parsing.
- Added evidence-backed proposal PAID path: direct approved→paid updates now fail unless transaction-local evidence gate is set by `confirm_proposal_paid_from_import`.
- PAID evidence requires supervisor+, latest approved+applied exact proposal match, source semantic `production_report`, explicit canonicalStatus=paid, raw status and occurredAt.
- Adversarial correction: raw strings such as “pago/liberado” are NOT auto-mapped to paid; generic production adapter requires an explicit canonical-status column.
- Proposal status evidence is append-only/idempotent and tenant-scoped.
- Runtime: confirm_proposal_paid_from_import SECURITY INVOKER; authenticated=true; anon=false. Security Advisor 0 ERROR; only known leaked-password WARN + intentional platform INFO remain.
- Remaining validation boundary is Vercel typecheck/build for this full wave plus external Supabase leaked-password setting before real production.


## Continuous closure after auth hardening
- Revalidated live critical closure RPCs: generate_import_match_candidates, freeze_proposal_commercial_route, confirm_proposal_paid_from_import, and publish_financial_fact_from_import_decision are SECURITY INVOKER; authenticated=true; anon=false.
- Live closure tables remain empty for component snapshots/status evidence, so no production facts were fabricated during validation.
- Review found stale import error copy after native XLSX support; corrected to advertise CSV/XLSX/XLS-HTML accurately.
- Continue from commit 49c1249b; Vercel preview validation required for this HEAD, but no new external configuration is currently needed.


## E2E/adversarial closure contract correction
- Re-ran the MVP closure SQL against live Supabase and initially got a false failure because the test expected a non-existent dedicated paid trigger name.
- Confronted live trigger/function definitions: paid evidence enforcement is correctly embedded in guard_proposal_status_transition via corban.paid_evidence_rpc and paid_requires_confirmed_operational_evidence.
- Corrected the contract to inspect the actual guard implementation and added confirm_proposal_paid_from_import to RPC exposure checks.
- Re-ran corrected contract against live DB: [] (zero failures).
- This is a test correction, not a weakening of the paid evidence invariant.


## MVP UX closure wave
- Added Rede comercial, Importações, Financeiro and Configuração to primary authenticated navigation; previously implemented modules are now reachable without manual URLs.
- Removed duplicate production_report semantic option in source creation.
- Exposed the existing generic production/status adapter in import adapter selection; source semantic and adapter semantic remain fail-closed in ingestion.
- Reconfirmed generic production adapter only maps canonical paid when the source explicitly supplies canonical_status=paid; arbitrary raw status is preserved but not promoted.


## Operational UX closure
- Added direct proposal navigation from digitization queue and operational cases.
- Adversarial review caught an attempted customer-list link before its target route existed; reverted immediately, then implemented the target safely and re-enabled navigation.
- Added tenant-safe Customer 360 detail at /app/clientes/[id] using RLS-backed client/proposal/document metadata queries; CPF remains masked and private document bytes are never exposed.
- Confronted live proposals_v2 schema to confirm customer_id exists before accepting the Customer 360 query.
- No production data mutation performed by this UX wave.


## Joint ChatGPT + Claude Code execution protocol — 18/09/2026
- Coordination contract added at `/.ai/CLAUDE-LONG-RUN.md` (commit `f15d0d7`).
- Claude Code long queue: reconcile live integration schema with repo; finish deterministic 2Tech BuscaContrato adapter; canonical normalization; conflict/matching hardening; operational/financial linkage; Import/Proposal/Finance UX; adversarial tests/build.
- Bevicred live authentication/API key is deferred and must not block this queue.
- Claude should inspect/use available token-saving/codebase tools when appropriate (Graphify, Caveman, Superpowers, context-mode, Context7/official docs), reuse indexes/caches, and avoid repeated large-file reads.
- Git + state files are the handoff bus; the user is not a courier between ChatGPT and Claude.
- ChatGPT may advance live Supabase; Claude reconciles through forward-only migrations and never rewrites applied history.


## LONG-RUN handoff — 18/09/2026 (blocos A–G)
**Concluído (commits em `architecture/corban-os-master-v2`):**
- A: 7 migrations espelho do estado live em `supabase/migrations/20260918_*` (contrato de integração, guards, execution ledger, mapeamentos, imutabilidade raw, dedupe de policy). Nada re-aplicado.
- B: `src/lib/imports/twotech.ts` (adapter `2tech/busca_contrato_file`), registrado em `adapters.ts`/`engine.ts` e na tela de importação (`sourceKey=2tech_busca_contrato`, exige fonte `production_report`).
- C/D: `canonical.ts` e `conflicts.ts`.
- E: código financeiro existente auditado; defeitos achados e corrigidos em migrations PREPARADAS (abaixo). Dashboard já subtrai reversões quando existirem.
- F: tela de lote (linhagem, conflitos, evidência por linha), RBAC de comissão/financeiro.
- G: `npm run test:unit` = 31 passam; `tsc` limpo; `eslint` 0 erros; `next build --webpack` passou (antes das últimas edições de RBAC; typecheck e lint rodados depois).

**Human Gate acumulado (nada disso aplicado no Supabase remoto):**
1. `20260919_revoke_excess_table_privileges_v1.sql` — ALTA prioridade: `authenticated` tem TRUNCATE/REFERENCES/TRIGGER nas tabelas de tenant (ignora RLS e triggers de imutabilidade). Não é alcançável via PostgREST, mas é defesa em profundidade.
2. `20260919_financial_reversal_paths_v1.sql` — reconciliação hoje SOMA reversões; corrige netting, cria `publish_financial_reversal`, bloqueia INSERT direto de reversal/adjustment. Compilou em transação com rollback; nada persistido. Ao aplicar, adjustments diretos deixam de ser possíveis (não há uso no app).
3. `20260919_import_batch_adapter_lineage_v1.sql` — `attach_import_batch_adapter`; a action já chama a RPC de forma best-effort.
4. Após aplicar: rodar `tests/security/financial-reversal-paths-contract.sql`.

**Não feito / pendências reais:**
- Arquivo real BuscaContrato não disponível: aliases de colunas de identidade/instituição/produtor são provisórios e `KNOWN_TWOTECH_SCHEMA_FINGERPRINTS` está vazio.
- Testes A/B de tenant com JWT reais e testes comportamentais SQL (imutabilidade, FKs cross-tenant) exigem identidades de teste (banco live tem 0 usuários); não criei usuários artificiais.
- Máscara de comissão é a nível de aplicação; RLS não filtra colunas. Avaliar view/RPC segura antes de produção multi-perfil.
- Bevicred API segue adiada.
- Vercel: validar Preview do HEAD desta branch.

**Próxima tarefa executável:** com arquivo real BuscaContrato, registrar impressão de schema, confirmar aliases e adicionar teste com fixture anonimizada; após autorização, aplicar gates 1–3.


## LONG-RUN parte 2 — handoff 19/09/2026
**Commits (branch `architecture/corban-os-master-v2`):** `183075b` reversão parcial + attach por batch; `e5e3033` fixes RBAC helper/digest; `1f1c2fe` harness SQL; `8beb718` hardening de reconciliation cases; `4140082` pipeline genérico + fix HTML + matcher; rbac central; comissão exata; docs de auditoria/handoff (último commit desta lista).

**Migrations já aplicadas externamente:** `20260919_revoke_excess_table_privileges_v1` (ChatGPT). NÃO reaplicar.

**Migrations PREPARADAS, NÃO APLICADAS (aplicar nesta ordem, cada uma após autorização):**
1. `20260919_restore_rbac_helper_execute_v1.sql` — CRÍTICA: sem ela nenhuma escrita com RBAC funciona para usuário real.
2. `20260919_fix_digest_search_path_v1.sql` — CRÍTICA: ingestão e publisher de evidência.
3. `20260919_financial_reversal_paths_v1.sql` — reversão parcial, guard, refresh que subtrai, expected publisher governado.
4. `20260919_reconciliation_cases_write_hardening_v1.sql` — depende da 3.
5. `20260919_import_batch_adapter_lineage_v1.sql`.
Depois de aplicar: rodar `tests/security/financial-reversal-paths-contract.sql` (estrutural) e os dois `*-rollback.sql` (comportamentais; terminam em RAISE EXCEPTION por desenho — passa se a mensagem começar com `RESULTS: ALL PASS`).

**Testes:** `npm run test:unit` 48 passam; `tsc` limpo; `eslint` 0 erros; `next build --webpack` compilou; SQL rollback-only: 57/57 (reversão/attach/ingest) e 10/10 (reconciliation), com as migrations preparadas executadas na mesma transação e nada persistido (verificado depois).

**Achados:** ver `docs/audits/AUDIT-2026-09-19-TENANT-RESOLUTION-AND-LIVE-BLOCKERS.md` (classificação A/B/C de todas as funções com `limit 1`; blockers live; ledger).

**HUMAN GATES:** aplicar as 5 migrations acima; decidir modelo multi-org do app (hoje falha fechado com 2+ memberships); `create_customer_with_timeline` sem role check/tenant explícito (B); mascaramento de comissão por coluna exige view/RPC (B); Supabase Leaked Password Protection (externo). Bevicred segue adiada.

**Não feito:** UI de reversão/resolução de casos (depende das migrations aplicadas); tabela persistente de conflitos de importação (exigiria DDL novo); E2E com navegador (sem credenciais/usuário de teste); pipeline operacional/backend API além do que existe.

**Próximo ponto exato de retomada:** após o ChatGPT/usuário aplicar as migrations 1–2, rodar o harness rollback-only completo contra o live; então implementar UI de reversão (`publish_financial_reversal`) e resolução de casos em `/app/financeiro`, e o registro persistente de conflitos (`import_conflicts`) com DDL preparado. Com arquivo real BuscaContrato: registrar impressão de schema e confirmar aliases.


## LONG-RUN parte 3 — handoff 19/09/2026
**Commits (branch `architecture/corban-os-master-v2`, HEAD no push final):** `e6cd557` helper INVOKER + lineage em schema private + auditoria definer; `1f38dfe` UI financeira + ledger; `306f90f` conflitos/format detection/money; `ce…` E2E rollback + fixes de blockers; commit final de docs. (`git log --oneline` tem a lista completa.)

**LIVE (não reaplicar):** revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1.
**NOT LIVE (preparadas, aplicar nesta ordem após autorização):**
1. `20260919_fix_import_matching_uuid_aggregate_v1.sql` (matching + guard de candidatos) — CRÍTICA
2. `20260919_import_apply_rls_v1.sql` — CRÍTICA
3. `20260919_import_identity_case_normalization_v1.sql` — CRÍTICA (depende de 2 para o teste)
4. `20260919_financial_read_rbac_v1.sql` — reduz leitura de `agent`; app já gateia por role.
5. `20260919_rbac_helper_security_invoker_v1.sql` — remove o WARN do advisor.
6. `20260919_import_batch_adapter_lineage_v1.sql` (substituta segura, schema `private`).
7. `20260919_import_conflicts_v1.sql`.
Após aplicar: rodar os harnesses rollback-only (todos terminam em RAISE EXCEPTION; passam se a mensagem começa com `RESULTS: ALL PASS`) e os contratos estruturais (`security-definer-inventory-contract.sql`, `financial-reversal-paths-contract.sql`, `integration-contract-v1-contract.sql`).

**Testes:** `npm run test:unit` 65 passam; tsc limpo; eslint 0 erros; `next build --webpack` ok; SQL rollback-only: E2E financeiro 44/44, tenant A/B 19/19, conflitos 24/24, helper+lineage 32/32, reversão 57/57, reconciliation 10/10 (com as migrations preparadas executadas na mesma transação; nada persistiu).

**Bugs/vulnerabilidades desta rodada:** ver `docs/audits/AUDIT-2026-09-19-E2E-LIVE-BLOCKERS.md` e `AUDIT-2026-09-19-SECURITY-DEFINER.md` (min(uuid); apply sem policy; identidade duplicada por caixa; forja de candidato/identidade por agent; leitura financeira aberta; definer exposto).

**HUMAN GATES:** aplicar as 7 migrations; modelo multi-org do app (fail-closed com 2+ memberships); colunas de comissão em `proposal_commercial_snapshots`/`import_normalized_rows` (views por coluna); `product_table_external_identities` exige manager+ mas o RPC admite supervisor; identidade de teste para E2E de navegador; Leaked Password Protection; arquivo real BuscaContrato (aliases e fingerprint seguem PROVISÓRIOS/vazios). Bevicred adiada.

**Não feito:** E2E de navegador; entidade Lead; integração outbound de submissão; UI para conflitos persistidos (o lote recalcula ao vivo); views por coluna.

**Próximo ponto exato de retomada:** com as migrations 1–3 aplicadas, rodar o E2E rollback e habilitar a UI do lote a ler `import_conflicts`; depois views por coluna para comissão e seletor de organização multi-org.


## Revisão 3x de import_conflicts (9e6d851..321ac3d) — 19/09/2026
**Achados e correções (migration ainda NÃO live; nada aplicado):**
- Integridade conflict→raw_row→batch→tenant: o guard de `import_conflict_rows` já checava lote (9e6d851); adicionados: conflito sem evidência raw é rejeitado (`conflict_evidence_required`), raw ids duplicados são deduplicados (evitava erro de PK e quebra de idempotência), teto de 500 findings por chamada, `detail` limitado a 8000 bytes (CHECK), nota de resolução 10–2000 caracteres no RPC.
- UI do lote: três estados explícitos (tabela ausente `42P01/PGRST205`, falha de consulta = alerta vermelho, tabela disponível mesmo vazia); antes qualquer erro virava "indisponível" e tabela vazia exibia texto errado. Abertos primeiro, limite 50 visíveis, números das linhas raw exibidos, achados calculados (cross-lote) continuam visíveis com rótulo correto.
- Action `resolveImportConflict`: valida UUIDs, nota 10–2000, confirma que o conflito pertence ao lote (RLS+batch), `resolved_by/at` só do banco.
- Risco aceito (B): `detail` é informado pelo chamador supervisor+ e não é reverificado contra o raw; a evidência verificável são os vínculos às linhas raw imutáveis.
**Testes:** unit 65 ok; tsc limpo; eslint 0 erros; build ok; `tests/security/import-conflicts-rollback.sql` 30/30 (rollback-only, com a migration executada na mesma transação).
**LIVE (não reaplicar):** revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1. **NOT LIVE:** import_conflicts_v1 e as demais da lista anterior.
**Próximo ponto:** aplicar migrations 1–3 (matching/apply) e depois import_conflicts_v1; views por coluna para comissão; seletor multi-org.


## Live reconciliation correction — 19/09/2026 (ChatGPT)
Supabase `list_migrations` is authoritative for applied state. Confirmed LIVE; DO NOT REAPPLY:
- `20260919001901 fix_import_matching_uuid_aggregate_v1`
- `20260919001905 import_apply_rls_v1`
- `20260919001910 import_identity_case_normalization_v1`
- `20260919002119 rbac_helper_security_invoker_v1`
- `20260919002127 financial_read_rbac_v1`
- `20260919002148 import_batch_adapter_lineage_v1`
Also live from prior wave: revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1.
`import_conflicts_v1` remains NOT LIVE. Do not infer migration state from older handoff sections; query live migration history first.
Security Advisor at reconciliation: only 2 intentional INFO for closed platform-admin tables; no WARN/ERROR.
Column-level debt confirmed live: authenticated still has table-level SELECT on `import_normalized_rows` and `proposal_commercial_snapshots`; sensitive commission values coexist with operational fields. Do not revoke blindly because current import/proposal UI depends on operational columns. Next safe design is explicit role-scoped views/RPCs plus app cutover, then privilege reduction.


## Closure wave — handoff 20/09/2026 (para o ChatGPT)
**LIVE (confirmado; NÃO reaplicar):** revoke_excess_table_privileges_v1, restore_rbac_helper_execute_v1, fix_digest_search_path_v1, financial_reversal_paths_v1, reconciliation_cases_write_hardening_v1, fix_import_matching_uuid_aggregate_v1, import_apply_rls_v1, import_identity_case_normalization_v1, rbac_helper_security_invoker_v1, financial_read_rbac_v1, import_batch_adapter_lineage_v1.
**NOT LIVE — aplicar nesta ordem após autorização (cada uma tem harness rollback-only):**
1. `20260919_import_conflicts_v1.sql` — `tests/security/import-conflicts-rollback.sql` (30).
2. `20260920_column_security_and_tenant_derivation_v1.sql` — `tests/security/e2e-financial-flow-rollback.sql` (executar a migration antes, na mesma transação; ~70 checagens incl. colunas, multi-org, tenant B). ATENÇÃO: depois dela o app já usa `list_import_rows`/`get_commercial_route`; antes dela o app usa fallback operacional.
3. `20260920_reconciliation_resolution_immutability_v1.sql` — `tests/security/reconciliation-cases-hardening-rollback.sql` (17).
4. `20260920_leads_v1.sql` — `tests/security/leads-rollback.sql` (29).
Depois de aplicar: `tests/security/security-definer-inventory-contract.sql`, advisors de segurança/performance.
**Commits:** ver `git log 7d0385b..HEAD` (coluna+tenant, regressão NULL-role, app multi-org, resolução imutável, executor outbound, leads, docs).
**Testes:** unit 82; tsc; eslint 0 erros (4 warnings antigos/triviais); build; SQL rollback-only conforme acima, nada persistido.
**Bugs/vulnerabilidades:** ver `docs/audits/AUDIT-2026-09-20-CLOSURE-WAVE.md`.
**HUMAN GATES:** aplicar as 4 migrations; decidir se `agent` pode ver comissão da PRÓPRIA simulação/proposta (`proposals_v2`, `simulations`); identidade de teste para E2E de navegador; Leaked Password Protection; arquivo real BuscaContrato (aliases/fingerprint seguem provisórios); Bevicred adiada.
**Dependências externas:** nenhuma credencial usada; nada enviado a provider real.
**Não feito:** UI de conflitos além do lote; intake de leads por webhook (WhatsApp/Meta) — o schema já suporta external_ref; persistência do executor em `integration_runs` (interface pronta, adapter Supabase não escrito); E2E de navegador.
**Retomada exata:** após aplicar 1–4 rodar os harnesses; então escrever o repositório Supabase do executor (`RunRepository` -> `integration_runs`/`integration_run_artifacts`) e o primeiro provider real (não Bevicred) com allowExternal controlado.


## LIVE closure-wave application — 19/09/2026 (ChatGPT)
User authorized the live Human Gate with "continue". Applied successfully, in order, and verified after each step:
- `20260919024443 import_conflicts_v1`
- `20260919024457 column_security_and_tenant_derivation_v1`
- `20260919024513 reconciliation_resolution_immutability_v1`
- `20260919024526 leads_v1`
Post-apply checks: conflict tables/functions exist; authenticated lost direct table SELECT on mixed economic tables and must use governed RPCs; anon cannot execute private economic readers; reconciliation guard contains immutable-resolution enforcement and refresh preserves resolved status; leads/lead_events exist, authenticated has no direct INSERT/UPDATE/DELETE, lead RPC is executable, anon cannot execute private.lead_write; lead/event counts remain zero.
Security Advisor after application: no WARN/ERROR; only the same 2 intentional INFO for closed platform admin tables.
Performance Advisor found one new actionable INFO: composite FK `leads(organization_id,customer_id)` lacked a covering index. Added repo migration commit `0ebb7f7` and applied live as `20260919024604 leads_customer_fk_index_v1`. Re-run removed the unindexed-FK finding. Remaining performance findings are unused-index INFO expected on the near-empty database plus Auth fixed connection-count INFO.
No synthetic business/test rows were persisted.
Next execution target: implement Supabase `RunRepository` for outbound executor against existing `integration_runs` / `integration_run_artifacts`, with tests and no real provider/network calls.


## Operational integration wave — handoff 21/09/2026 (para o ChatGPT)
**LIVE (não reaplicar):** todas as anteriores + import_conflicts_v1, column_security_and_tenant_derivation_v1, reconciliation_resolution_immutability_v1, leads_v1, leads_customer_fk_index_v1.
**(SUPERADO: ambas estão LIVE, ver seção 'LIVE operational integration application') — histórico do que foi preparado:**
1. `20260921_integration_run_state_machine_v1.sql` — `integration-runs-rollback.sql` (111 checagens). Colunas de lease/fencing, trigger de estados, artefatos append-only, guarda de segredos, funções de worker só `service_role`, SELECT de runs/artifacts restrito a supervisor+. Sem SECURITY DEFINER novo.
2. `20260921_operational_pipeline_write_hardening_v1.sql` — coberta por `operational-e2e-rollback.sql` (executar as DUAS migrations no mesmo bloco antes). Redefine `send_proposal_to_digitization` (mesmo corpo + token) e revoga DELETE/UPDATE em excesso.
**Depois de aplicar:** rodar `security-definer-inventory-contract.sql`, advisors de segurança/performance, e o worker: `new SupabaseRunRepository(createAdminClient())` (service role, servidor apenas).
**Testes:** unit 105; tsc 0; eslint 0 erros (4 warnings antigos); build ok.
**Bugs/vulnerabilidades:** ver `docs/audits/AUDIT-2026-09-21-OPERATIONAL-INTEGRATION-WAVE.md` (esteira forjável, ledger sem state machine, payload bruto legível, segredo persistível).
**HUMAN GATES:** aplicar as 2 migrations; arquivo real BuscaContrato (homologação em `docs/integrations/2TECH-BUSCACONTRATO-HOMOLOGATION.md`); regra de visibilidade de comissão em `proposals_v2`/`simulations` para agent; adapter catalog: cadastrar linha `local/fake` só em ambiente de teste (nunca em produção); Leaked Password Protection.
**Dependências externas:** nenhuma credencial usada; nenhuma chamada de rede; nenhum provider real iniciado.
**Não feito:** worker/cron que chama `executeRun` (interface pronta, sem processo agendado); botão de cancelar/reexecutar na UI (RPC `cancel_integration_run` existe); provider real.
**Retomada exata:** após autorização aplicar a migration 1, criar rota/worker servidor que instancie `SupabaseRunRepository` + `executeRun` com o provider `local/fake` num binding de teste (rollback-only), depois escolher o primeiro provider real quando houver arquivo/credencial.


## LIVE operational integration application — 19/09/2026 (ChatGPT)
Applied after reviewing Claude HEAD `a2aa621` and reconciling against live migration history:
- `20260919035427 integration_run_state_machine_v1`
- `20260919035447 operational_pipeline_write_hardening_v1`
Both applied successfully; DO NOT REAPPLY.
Post-apply verification: integration_runs now has lease/fencing/state columns; security advisor remains 0 WARN / 0 ERROR with only the same two intentional INFO on closed platform-admin tables. Performance advisor has no new actionable FK warning; remaining findings are unused-index INFO on the near-empty database plus Auth fixed connection-count INFO.
No synthetic operational data persisted: integration_runs=0, integration_run_artifacts=0, operational_events=0, digitization_jobs=0, operational_cases=0 at verification.
Next execution target: server-only worker/route that instantiates SupabaseRunRepository(createAdminClient()) and executeRun. Keep local/fake confined to rollback/test; no real provider/network call. Add governed cancel/retry UI only after worker path is proven. proposals_v2 direct UPDATE and customer_timeline_events direct INSERT remain explicit security debt to review before production.


## Worker + governance wave — handoff 22/09/2026 (para o ChatGPT)
**LIVE (não reaplicar):** todas as anteriores, inclusive `integration_run_state_machine_v1` e `operational_pipeline_write_hardening_v1`.
**ACHADO URGENTE NO LIVE:** `public.transition_operational_case` (usada por `/app/operacao`) grava em `operational_cases`/`digitization_jobs`/`operational_events`/`proposals_v2` sem o token que o hardening LIVE passou a exigir → toda transição de esteira falha hoje. Corrigida em `20260922_worker_governance_v1.sql` (NOT LIVE). Sugestão: aplicar esta migration antes de qualquer uso da esteira.
**NOT LIVE — `20260922_worker_governance_v1.sql`** (harness `tests/security/worker-governance-rollback.sql`, executar a migration antes na mesma transação; pré-requisitos todos LIVE):
1. HOTFIX `transition_operational_case` + `send_proposal_to_digitization` com token de proposta.
2. `proposals_v2`: escrita só por RPC (`create_proposal_from_simulation`, `prepare_proposal_documents`, `send_proposal_to_digitization`, `transition_operational_case`; `confirm_proposal_paid_from_import` já tem seu token), identidade imutável, sem DELETE.
3. `customer_timeline_events`: append-only + insert só por RPC (`create_customer_with_timeline` redefinida; `lead_write` DEFINER segue pelo caminho do owner).
4. Worker: `enqueue_integration_run`, `list_dispatchable_integration_runs`, `create_integration_reexecution` (service_role, SECURITY INVOKER) + colunas `parent_run_id` / `reexecution_reason`.
Sem SECURITY DEFINER novo; inventário inalterado.
**Como operar o worker:** definir `INTEGRATION_WORKER_SECRET` (>=24 chars) no servidor; `POST /api/integrations/dispatch` com `Authorization: Bearer <segredo>`; nada é agendado. Fake local só com `CORBAN_ALLOW_LOCAL_PROVIDERS=1` fora de produção. Ver `docs/integrations/WORKER-DEPLOYMENT.md`.
**Requests devem conter referências, não PII** (o payload persistido é redigido; CPF/tokens viram máscara).
**HUMAN GATES:** aplicar a migration; definir o segredo do worker e o agendador; arquivo real 2Tech; Leaked Password Protection; regra de comissão visível ao agent em `simulations`.
**Não feito:** agendador/cron; provider real; catálogo com linha `local/fake` (só em teste); UI de linhagem completa (mostra o pai da nova execução).


## LIVE worker governance application — 19/09/2026 (ChatGPT)
User explicitly authorized the Human Gate ("pode aplicar"). Applied successfully:
- `20260919044054 worker_governance_v1`
DO NOT REAPPLY.
Verified live after application:
- `transition_operational_case` now sets both `corban.operational_rpc` and `corban.proposal_rpc`; the regression introduced by the prior operational hardening is closed.
- `send_proposal_to_digitization` sets the proposal token.
- `integration_runs.parent_run_id` and `reexecution_reason` exist.
- dispatch RPC is executable by `service_role` and denied to `authenticated` / `anon`.
- no integration run/artifact fixture persisted (0/0 at verification).
- SECURITY DEFINER inventory is unchanged: 8 reviewed functions; all pin empty search_path; no anon EXECUTE; no new definer.
- Security Advisor: 0 WARN / 0 ERROR, only the same 2 intentional INFO on closed platform-admin tables.
- Performance Advisor: no new actionable warning; unused-index INFO reflects the near-empty database, plus Auth fixed connection-count INFO.
Next target: regression verification against the now-migrated live schema (integration-runs + operational E2E patterns), then configure a worker secret/scheduler only with an explicit deployment/configuration gate. No provider real/network call.


## Live regression + worker proof + scheduler readiness — handoff 23/09/2026 (para o ChatGPT)
**LIVE (não reaplicar):** todas, inclusive `worker_governance_v1` (20260919044054). O hotfix de `transition_operational_case` está comprovado LIVE (agent/supervisor movem a esteira; direto continua bloqueado; `paid` continua exigindo fonte financeira).
**Regressão LIVE executada (rollback-only, sem preludes):** worker governance 125/125, integration runs 111/111, operational E2E 72/72, financial E2E 93/93, leads 47/47 (o E2E financeiro e o de leads usam os caminhos de cliente/timeline/proposta alterados por worker_governance). Não rerodados: import conflicts (30) e reconciliation (18) — nada do que tocam mudou. Sem resíduo: runs/artifacts/leads/propostas/esteira/timeline/clients/financial_events = 0.
**NOT LIVE — revisar e aplicar (2 migrations pequenas e independentes):**
1. `20260923_worker_dispatch_hardening_v1.sql` — harness `tests/security/worker-dispatch-hardening-rollback.sql` (executar a migration antes, mesma transação). Substitui `list_dispatchable_integration_runs` (nova assinatura com `p_adapter_keys`; a antiga é dropada), `fail_integration_run` e `claim_integration_run` (histórico `diagnostic` por tentativa/lease expirado; mensagem hostil não trava). Sem SECURITY DEFINER novo. ATENÇÃO: o código novo do worker já chama a assinatura nova; aplicar a migration antes de habilitar o dispatch (hoje ele nem está habilitado: sem segredo).
2. `20260924_confirm_paid_replay_v1.sql` — harness `tests/security/proposal-paid-evidence-rollback.sql` (18 checagens). Só o replay de `confirm_proposal_paid_from_import` passa a devolver a evidência existente.
**Como o scheduler pode ser acionado:** ver `docs/integrations/WORKER-DEPLOYMENT.md` (Vercel Cron, n8n, GitHub Actions ou fila chamam `POST /api/integrations/dispatch` com Bearer; nada foi configurado).
**Testes locais:** unit 152 (novos 27 em worker-hardening), tsc 0, eslint 0 warnings, build ok.
**HUMAN GATES:** aplicar as 2 migrations; definir `INTEGRATION_WORKER_SECRET` e o agendador; arquivo 2Tech; regra de comissão do agent; convites/gestão de usuários da organização (ver `docs/PILOT-GAP-ANALYSIS.md`).
**Retomada exata:** após aplicar as migrations, rodar `worker-dispatch-hardening-rollback.sql` de novo já sem prelúdio (modo LIVE), e então testar o worker real com `CORBAN_ALLOW_LOCAL_PROVIDERS=1` em ambiente NÃO produtivo contra um binding de teste.


## LIVE closure migrations — 19/09/2026 (ChatGPT)
User explicitly authorized both reviewed migrations. Applied successfully, in order:
- `20260919140756 worker_dispatch_hardening_v1`
- `20260919140800 confirm_paid_replay_v1`
DO NOT REAPPLY.

Post-apply verification:
- new 3-argument `list_dispatchable_integration_runs(integer,timestamptz,text[])` exists; old 2-argument overload is gone;
- dispatch remains service_role-only; authenticated/anon denied;
- immutable diagnostic history is present in fail/takeover paths;
- secret-looking failure redaction is active;
- PAID confirmation replay path is present and idempotent;
- `integration_runs=0`, `integration_run_artifacts=0` immediately after verification;
- SECURITY DEFINER inventory remains exactly 8 reviewed functions, all with pinned empty search_path; no anon EXECUTE;
- Security Advisor: 0 WARN / 0 ERROR; only 2 intentional INFO for closed platform-admin tables;
- Performance Advisor: only INFO (unused indexes on near-empty DB + Auth fixed connection allocation); no new actionable warning.

Next P0 work is product/deployment rather than these migrations: organization user invitation/access lifecycle, worker secret+scheduler activation, and commercial decision on agent commission visibility. Real 2Tech remains blocked on a real file; Bevicred remains deferred.


## Pilot readiness wave - handoff 24/09/2026 (para o ChatGPT)
**LIVE (nao reaplicar):** tudo ate 20260924, incluindo worker_dispatch_hardening_v1 e confirm_paid_replay_v1.
**NOT LIVE - revisar e aplicar:** `supabase/migrations/20260925_team_access_lifecycle_v1.sql`. Cria `organization_invitations`, `organization_admin_events`, policies de time em `organization_memberships`, revoga INSERT/DELETE e restringe UPDATE a `role,status,updated_at` para `authenticated`, guard triggers e 5 RPCs INVOKER (`create_organization_invitation`, `revoke_organization_invitation`, `set_member_role`, `set_member_status` para authenticated; `accept_organization_invitations` so service_role) + `can_manage_member_role`. Sem SECURITY DEFINER novo. Harnesses: `tests/security/team-access-rollback.sql` (rodar o texto da migration antes, mesma transacao; 131 checagens) e `tests/security/pilot-e2e-rollback.sql` (45 checagens). Depois de aplicada, rodar ambos so com o bloco DO (modo LIVE).
**Antes de convidar alguem em producao (gates externos):** Supabase Auth > URL Configuration: Site URL e Redirect URL `<origin>/auth/definir-senha`; SMTP proprio; opcional template com `token_hash` apontando para `/auth/confirm`. Segredo do worker e agendador: `docs/integrations/WORKER-DEPLOYMENT.md`.
**Decisao humana pendente:** o agente pode ver comissao esperada? App: fail-closed centralizado em `canViewCommission`. Banco: colunas `expected_commission_amount` legiveis por qualquer membro (RLS por linha); fechar exige nova migration depois da decisao.
**Testes locais:** unit 171/171, tsc 0, eslint 0 warnings, build ok.
**Retomada exata:** aplicar a migration, rodar os dois harnesses em modo LIVE, testar convite real com um e-mail do Owner em ambiente com SMTP configurado, e so entao ativar segredo+agendador do worker.


## Team access lifecycle LIVE — 19/09/2026 (ChatGPT)
Owner explicitly authorized the reviewed team-access migration. Applied successfully:
- `20260919160840 team_access_lifecycle_v1`
DO NOT REAPPLY.

Post-apply verification:
- `organization_invitations` and `organization_admin_events` exist with RLS policies;
- `authenticated` no longer has direct INSERT/DELETE on `organization_memberships`; governed column UPDATE remains behind trigger/RPC;
- invitation acceptance RPC is service_role-only; authenticated/anon denied;
- invitation creation RPC remains authenticated with internal RBAC;
- invitation/admin-event tables contain 0 rows immediately after apply;
- integration runs/artifacts/financial events/reconciliation all remain 0;
- SECURITY DEFINER inventory remains exactly 8; anon EXECUTE count 0;
- Security Advisor remains 0 WARN / 0 ERROR, with only the two intentional INFO findings for closed platform-admin tables.

Next external/pilot gates: configure Supabase Auth Site URL + redirect URL + SMTP, then execute a real Owner invitation test. Worker secret/scheduler activation and commission-visibility business decision remain separate Human Gates.


## Pilot closure wave 2 - handoff 24/09/2026 (para o ChatGPT)
**LIVE (nao reaplicar):** tudo ate 20260925 (team access, aplicada como 20260919160840).
**NOT LIVE - revisar e aplicar, nesta ordem (independentes, ambas so forward, sem DEFINER):**
1. `supabase/migrations/20260926_simulation_governance_v1.sql` - `create_simulation` (INVOKER), guard trigger `simulations_00_governed_write`, revoga INSERT/UPDATE/DELETE de authenticated e concede INSERT nas colunas derivadas e UPDATE(status,updated_at); re-declara `create_proposal_from_simulation` com UMA mudanca (o flip para `selected` roda dentro do token). Harness: `tests/security/simulation-governance-rollback.sql` (rodar o texto da migration antes; 54/55 na primeira execucao, a unica falha era expectativa do harness sobre UPDATE de 0 linhas, ja reescrita) + `tests/security/pilot-e2e-v2-rollback.sql` (39/39). Depois de aplicada, rodar ambos so com o bloco DO e remover o fallback `legacyInsert` em `src/app/app/simulacoes/actions.ts`.
2. `supabase/migrations/20260927_membership_select_policy_merge_v1.sql` - junta `select_self` e `select_team` numa policy (advisor WARN). Harness: `tests/security/membership-policy-merge-rollback.sql` (12/12).
**Depois de aplicadas:** rode o advisor de performance (o WARN de `organization_memberships` deve sumir).
**Gates externos (Owner):** `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md` (Site URL, Redirect URLs, SMTP, politica de senha, teste humano de convite); segredo e agendador do worker (`docs/integrations/WORKER-DEPLOYMENT.md`, com cadencia recomendada).
**Decisao humana pendente:** o agente pode ver comissao esperada? (centralizado em `canViewCommission`; colunas do banco ainda legiveis por membros).
**Testes locais:** unit 189/189, tsc 0, eslint 0 warnings, build ok.


## Pilot closure wave 3 - handoff 25/09/2026 (para o ChatGPT)
**LIVE (nao reaplicar):** ate 20260927; simulation governance ativa; fallback do app removido.
**NOT LIVE - revisar e aplicar:** `supabase/migrations/20260928_revoked_actor_dispatch_v1.sql` (substitui `list_dispatchable_integration_runs` mantendo a assinatura; cria `sweep_orphaned_integration_runs`, service_role, INVOKER). Harness: `tests/security/revoked-actor-dispatch-rollback.sql` (`__FIXED__` = false no schema atual prova o bug, 6/6; `true` com o texto da migration, 22/22). Depois de aplicar: rodar com `__FIXED__=true` so o bloco DO. O codigo do worker ja chama o sweep e tolera a ausencia da funcao.
**Produto:** `docs/pilot/*` (checklist, setup do Owner, guias). A organizacao Smart Promotora NAO existe; procedimento de criacao no OWNER-SETUP (POST /api/admin/organizations como administrador de plataforma; nao repetir).
**Gates externos:** Auth (Site URL, Redirect URL, SMTP, politica de senha), publicar o app, catalogo comercial da Smart (tabela publicada, checklist, etapas), decisao de comissao do operador, worker (segredo + agendador), teste humano de convite.
**Testes locais:** unit 211/211, tsc 0, eslint 0, build ok.
**Retomada exata:** aplicar 20260928; Owner cumpre o OWNER-SETUP; um humano faz o passo 7 (aceitacao) e o checklist ANTES; so entao o operador real.


## Revoked-actor dispatch LIVE — 19/09/2026 (ChatGPT)
Revisada contra o schema LIVE e aplicada com sucesso:
- `20260919194224 revoked_actor_dispatch_v1`
DO NOT REAPPLY.

Validação independente:
- harness completo com a migration em transação rollback-only: `RESULTS: ALL PASS (22 checks)`;
- harness novamente contra o schema já LIVE, somente bloco DO com `fixed=true`: `RESULTS: ALL PASS (22 checks)`;
- `sweep_orphaned_integration_runs(integer,timestamptz)` existe e é EXECUTE somente por `service_role`; authenticated/anon negados;
- inventário SECURITY DEFINER permanece 8; anon EXECUTE = 0;
- Security Advisor: 0 WARN / 0 ERROR; apenas 2 INFO intencionais das tabelas administrativas fechadas;
- Performance Advisor: sem WARN novo; apenas INFO de índices ainda não usados no banco praticamente vazio + Auth fixed connection allocation;
- zero resíduo sintético: integration_runs=0, integration_run_artifacts=0, financial_events=0, reconciliation_cases=0.

O P0 de starvation por ator revogado está fechado no LIVE. Próximo alvo é implantação do piloto Smart: organização Smart, deploy/origin, Auth/SMTP, catálogo comercial e teste humano no navegador. Worker secret+scheduler continuam desativados até gate externo.


## Deployment & tenant wave 4 - handoff 25/09/2026 (para o ChatGPT)
**LIVE (nao reaplicar):** ate `revoked_actor_dispatch_v1`.
**NOT LIVE - revisar e aplicar:** `supabase/migrations/20260929_catalog_publish_v1.sql` (INVOKER; guard trigger `guard_catalog_publication`; policies de UPDATE com transicao draft->published e supersede; RPCs `publish_product_table_version` e `publish_document_checklist_template`). Harness `tests/security/catalog-publish-rollback.sql` (texto da migration antes; 40/40). Depois de aplicada, rodar so o bloco DO. Sem ela o botao Publicar responde "recurso ainda nao disponivel".
**Pendencia P2:** revogar INSERT/UPDATE/DELETE de `authenticated` em `organizations` (RLS ja recusa).
**Owner:** ver `docs/deployment/SMART-DEPLOYMENT-RUNBOOK.md` (passos 1-10), `SUPABASE-AUTH-CONFIG.md`, `ENVIRONMENT-VARIABLES.md`, `docs/pilot/SMART-HUMAN-ACCEPTANCE-TEST.md`.
**Testes locais:** unit 229/229, tsc 0, eslint 0, build ok, preflight funcional (BLOCKED localmente por falta de SERVICE_ROLE no `.env.local`, esperado).


## Catalog publication LIVE + policy merge prepared — 19/09/2026 (ChatGPT)
Reviewed and applied successfully:
- `20260919231013 catalog_publish_v1`
DO NOT REAPPLY.

Independent validation:
- full catalog publication harness before apply: 40/40 PASS (rollback-only);
- full catalog publication harness against LIVE after apply: 40/40 PASS;
- publish RPCs exist; authenticated can execute, anon cannot;
- SECURITY DEFINER remains 8; anon DEFINER execute = 0;
- Security Advisor remains 0 WARN / 0 ERROR;
- zero synthetic residue in product_table_versions, document_checklist_templates, financial_events and reconciliation_cases.

Post-apply Performance Advisor found 2 new WARNs: multiple permissive UPDATE policies on `product_table_versions` and `document_checklist_templates`, introduced by the split draft/published policies in catalog_publish_v1.

Prepared, NOT LIVE:
- `20260930_catalog_update_policy_merge_v1.sql`
- harness `catalog-update-policy-merge-rollback.sql`

Evidence:
- policy merge harness: 4/4 PASS in rollback transaction;
- full catalog regression with the merge applied transactionally: 40/40 PASS.
The migration only merges equivalent permissive UPDATE policies; no grants, functions, triggers or data change.

HUMAN GATE: explicit authorization required before applying `20260930_catalog_update_policy_merge_v1` LIVE.


## Catalog update policy merge LIVE — 19/09/2026 (ChatGPT)
Authorized by Owner and applied successfully:
- `20260919231650 catalog_update_policy_merge_v1`
DO NOT REAPPLY.

Post-apply verification:
- rollback-only merge harness against LIVE: 4/4 PASS;
- `product_table_versions`: exactly 1 authenticated UPDATE policy;
- `document_checklist_templates`: exactly 1 authenticated UPDATE policy;
- Performance Advisor: the 2 `multiple_permissive_policies` WARNs are gone; remaining findings are INFO only (unused indexes on near-empty DB + Auth connection strategy);
- Security Advisor: 0 WARN / 0 ERROR; only the same 2 intentional INFO for closed platform-admin tables;
- SECURITY DEFINER inventory remains 8; anon DEFINER execute = 0;
- synthetic/business residue remains zero in product versions, checklists, financial events and reconciliation cases.

No known P0 technical blocker remains before Smart deployment preparation. Next gates are external/Owner actions: deploy/origin, env vars, Supabase Auth/SMTP, real reference catalog, Smart organization bootstrap, tenant catalog/checklist/stages, invitations, and human browser acceptance.


## Vercel reconnection and deployment discovery — 19/09/2026 (ChatGPT)
Vercel connector is now connected and the real account/project were discovered:
- team: `bossprt's projects` (`team_kBTHINjH2aw7k1uMZQwAh1SS`)
- project: `corban-saas` (`prj_X63Eyy85aWFU1DvPV0XtnM0F1BG5`)
- latest deployment discovered: `dpl_Bgtw1VJwWCqypgyQtF1Cyg3Cbp95`, state READY, source Git, branch `architecture/corban-os-master-v2`, commit `01011c74...`
- latest deployment target is null (preview, not production).
- no runtime logs found for the latest deployment in the last 24h.
- historical runtime error group (older deployment only): missing Supabase URL/key in middleware; last seen 18/09/2026. No evidence it affects the latest deployment.
- Preview deployment is protected by Vercel Authentication; connector could enumerate it but could not fetch app routes through protection.
- Current Vercel connector surface in this session does not expose environment-variable mutation, production promotion, or a working deploy action; deploy_to_vercel/build-log actions advertised by metadata were unavailable at runtime.

HUMAN GATE remains for Vercel project production configuration: production target/branch or promotion plus production environment variables. After that, ChatGPT can inspect deployment state/logs/runtime errors and continue acceptance checks.


## Vercel environment configuration — 19/09/2026 (Owner)
Owner confirmed the following Vercel environment variables were configured for the project:
- NEXT_PUBLIC_SUPABASE_URL
- NEXT_PUBLIC_SUPABASE_ANON_KEY
- NEXT_PUBLIC_SITE_URL
- SUPABASE_SERVICE_ROLE_KEY

Worker variables remain intentionally unset. This documentation commit also serves to trigger a fresh preview deployment so the new environment configuration is picked up.


## Vercel Production Branch — 19/09/2026 (Owner)
Owner changed Vercel Production Branch Tracking from `main` to `architecture/corban-os-master-v2`.
This commit intentionally triggers a fresh deployment so Vercel can promote/build this branch as Production.


## Independent Claude Audit — Health/Supabase production — 20/09/2026

Priority: independently verify the production health failure before any further manual configuration.

Claude executor instructions:
- Pull latest branch `architecture/corban-os-master-v2`.
- Read AGENTS.md, .ai/RULES.md, .ai/DECISIONS.md and this CURRENT-TASK first.
- Inspect `src/app/api/health/route.ts` and every Supabase env/config helper used by the deployed app.
- Verify whether `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` are the correct variables and whether using REST root `/rest/v1/` with only `apikey` is a valid reachability probe for the current Supabase setup.
- Check for middleware/redirect interference, malformed env names, whitespace/newlines, wrong key format, fetch behavior on Vercel, and any code path that could produce a false degraded result.
- Reproduce locally only if possible without inventing secrets; never print secrets.
- Prefer a safer health probe if the current one is semantically wrong. Do not weaken auth/RLS or expose secrets.
- Run tests/typecheck/build for any change.
- Do not touch live DB, production settings, secrets, or irreversible external state.
- Commit and push only reversible code/docs changes to this branch.
- Report: root cause, evidence, exact fix, tests, and whether any human action is still required.

## Independent Claude Audit result - Health/Supabase production - 20/09/2026 (Claude)
**Root cause (reproduced, no secret printed):** `/api/health` probed `GET <SUPABASE_URL>/rest/v1/` with only the publishable key. Supabase now answers that endpoint with `401 {"message":"Secret API key required"}` (the REST root/OpenAPI is secret-key-only). Every healthy deployment therefore reported `degraded` / `databaseReason: upstream_error, databaseUpstreamStatus: 401`. Not caused by env names (the right variables), whitespace/newlines (local values clean), middleware (`/api/health` is exempt and the probe is server-side), or Vercel fetch behaviour.
**Evidence (local, same project, real publishable key, values never printed):** REST root + apikey = 401 Secret API key required; REST root without key = 401 No API key; `/auth/v1/health` + apikey = 200; PostgREST query on a table anon cannot read = 401 with Postgres code 42501 (the database itself answered); wrong key = 401 "Invalid API key" (no Postgres code).
**Fix:** probe = Auth health (200) AND a real PostgREST query on `organizations` (200, or 401/403 carrying a Postgres SQLSTATE such as 42501 = database reachable). Bad/missing key, PostgREST-only codes, 4xx/5xx gateway errors, timeouts remain `degraded` with fixed reason codes (`bad_key`, `upstream_error`, `timeout`, `network_error`, `missing_url`, `missing_key`). Response adds `auth`. No secret, no admin client, RLS untouched, still cached 5 s. Env values are now trimmed (and a trailing slash removed from the URL) in health, server/middleware clients, browser client and admin client.
**Tests:** unit 234/234 (5 new in `health.test.ts`), tsc and eslint clean, `next build` ok.
**Human action still required:** none for this bug. After the next deployment, `<APP_ORIGIN>/api/health` should return `{"status":"ok","app":"ok","database":"ok","auth":"ok"}`. If the preview is behind Vercel Deployment Protection the request is blocked before reaching the app (that is not this bug).


## Production site origin corrected — 20/09/2026
Owner confirmed Vercel NEXT_PUBLIC_SITE_URL was changed to https://corban-saas.vercel.app for all environments.
This commit intentionally triggers a fresh production deployment so auth e-mail redirects use the official origin.


## Commercial Model V3 — Owner decision 19/09/2026

**Fonte de verdade funcional:** `docs/CORBAN-COMMERCIAL-MODEL-V3.md`.

O Owner validou, após teste real como Smart Promotora, que o tenant precisa ter autonomia comercial. A modelagem anterior causava dependência indevida do Platform Admin.

### Decisões aprovadas
- Platform Admin = estrutura padrão, templates e dados realmente universais.
- Tenant Admin = bancos/instituições, provedores/masters, convênios habilitados/próprios, Produto/Tabela comercial, prazos, coeficientes, comissão recebida, grupos e repasses.
- Vocabulário operacional: `Banco → Convênio → Produto (Tabela) → Tipo de Contrato → Prazo → Coeficiente/Taxa → Comissão recebida → Grupos de Comissão`.
- “Modalidade” deve aparecer ao usuário como **Tipo de Contrato**.
- Tipo de Contrato NÃO deve depender de Produto.
- Produto operacional do Owner = **Tabela comercial**, não categoria genérica global.
- Convênio nacional não deve nascer preso a banco.
- Pré-carregar templates: 27 governos estaduais/GDF + 26 prefeituras de capitais; tenant habilita/desabilita, pode editar dados permitidos e cadastrar adicionais.
- Códigos técnicos são internos/automáticos e não devem aparecer como campo obrigatório.
- Grupos de comissão são dinâmicos e tenant-owned; uma única condição comercial deve permitir cadastrar a distribuição de todos os grupos, inclusive importação com coluna por grupo.
- Comissão recebida pela empresa é separada de regra de repasse.
- Gerente/supervisor são opcionais e configuráveis por regra/base de cálculo.
- Manual, CSV/XLSX e API futura convergem para o mesmo modelo interno.

### Estado técnico atual relevante
- UI já renomeou “Modalidades” para “Tipos de Contrato”.
- Produto, Tipo de Contrato, Convênio e Tipo de Documento já passaram a gerar código técnico automaticamente na UI atual; porém a modelagem relacional ainda é antiga.
- `products` global genérico, `modalities.product_id` e `agreements.bank_id` entram em conflito com o modelo aprovado.
- NÃO corrigir isso com renome destrutivo. Auditar dependências e preparar migração compatível.
- `ProductTable/ProductTableVersion` deve ser avaliado como possível fonte de verdade do Produto/Tabela operacional.

### Próxima execução
Claude deve:
1. ler AGENTS/RULES/DECISIONS/CLAUDE-LONG-RUN + `docs/CORBAN-COMMERCIAL-MODEL-V3.md`;
2. auditar schema/migrations/RLS/RPC/UI/testes de catálogo, comissões e proposals;
3. produzir plano de migração mínimo e seguro;
4. implementar tudo reversível na branch `architecture/corban-os-master-v2`;
5. testar unit/tsc/eslint/build + SQL rollback-only/adversarial;
6. atualizar docs e handoff;
7. parar antes de DDL LIVE e pedir Human Gate com evidências.

**Não trabalhar na main. Não aplicar DDL LIVE sem autorização explícita.**

## Commercial Model V3 - implementacao (Claude) - 26/09/2026
**Estado:** implementado na branch, testado; migration PREPARADA, NAO aplicada. Auditoria: `docs/audits/AUDIT-2026-09-26-COMMERCIAL-MODEL-V3.md`. ADR-0024.

**Feito:** migration `20261002_commercial_model_v3_foundation_v1` (aditiva, INVOKER, RLS em todas as tabelas novas); harness `tests/security/commercial-model-v3-rollback.sql` (139 checks, `RESULTS: ALL PASS`, zero residuo); politica de repasse versionada (bruta/liquida, override rastreavel) e Origem da Producao Propria/Terceiro (V3 §19.3/§20) ja dentro da MESMA migration; teto por grupo (grupos sao alternativos); `src/lib/commercial.ts` + `commercial-xlsx.ts`; `/app/comercial` (bancos, provedores, convenios nacionais/proprios, grupos, tabelas, condicao unica, importacao CSV/XLSX por grupo, publicar); simulacao por condicao; configuracao V3; 29 testes unitarios novos (263/263), tsc, eslint, build verdes.

**HUMAN GATE (unico pendente):** autorizar aplicar `20261002_commercial_model_v3_foundation_v1` LIVE (DDL em producao: 12 tabelas novas, `organization_product_routes` alterada, `publish_product_table_version` substituida). Depois de aplicar: rodar o harness (rollback-only), advisors (RLS), inventario DEFINER (deve seguir igual).

**Adiado por exigir Human Gate proprio (chave de IA / gasto):** agente de importacao por IA, PDF, metering de creditos, agente operacional (V3 §20.6, §21-§23). **Adiado por ser independente:** CEP com preenchimento automatico (V3 §19.1).

**Proxima onda (nao exige Human Gate):** RPC de importacao em transacao unica; ligar grupos ao snapshot/split/repasse; UI Platform Admin para templates; aposentar catalogo global legado com plano de migracao de dados.


## Commercial Model V3 LIVE — 20/09/2026

Owner authorized and ChatGPT applied `20261002_commercial_model_v3_foundation_v1.sql` LIVE. Supabase registered it as `20260920133017 commercial_model_v3_foundation_v1`. **DO NOT REAPPLY.**

Verification:
- rollback-only LIVE harness: 139/139 PASS (expected final RAISE used as rollback sentinel);
- RLS enabled on all 12 new V3 tables;
- 4 contract types + 53 national public-agreement templates seeded;
- zero tenant/business V3 residue immediately after apply;
- SECURITY DEFINER app inventory still 8 total (6 private + 2 public), none introduced by V3;
- Security Advisor: no WARN/ERROR, only 2 known intentional INFO on platform-admin tables;
- Performance Advisor: INFO only, including 11 unindexed-FK candidates on V3 tables. No WARN/ERROR.

Next product/engineering targets from `docs/CORBAN-COMMERCIAL-MODEL-V3.md`:
1. real Smart tenant configuration through `/app/comercial`;
2. CEP autofill;
3. adaptive AI import agent (Gemini preferred initial provider, provider-agnostic);
4. AI metering/credits and pass-through cost;
5. operational monitoring agent / Action Center;
6. proposal snapshot + payout execution linkage;
7. atomic bulk import for conditions.

Keep all future decisions persisted in repo docs before chat context is lost.


## Próxima wave preparada — UX, importação atômica e agentes

Fonte operacional detalhada: `docs/NEXT-WAVE-PLAN-V3.md`.

Prioridade de execução:
1. validar e polir `/app/comercial` como tenant real;
2. CEP automático no cadastro/edição de cliente;
3. importação comercial atômica em lote;
4. fundação provider-agnostic do Agente de Importação IA, com Gemini como default inicial e fake provider para testes;
5. metering/créditos de IA;
6. Action Center / Agente Operacional deterministic-first;
7. integração de payout/snapshot com o financeiro existente.

Regras:
- sem main;
- sem secret Gemini real;
- sem gasto;
- sem DDL LIVE;
- sem mudança financeira irreversível;
- tudo reversível pode ser preparado/testado/commitado/pushado na branch;
- parar em Human Gate real com evidências.

## Proxima wave V3 - execucao (Claude) - 20/09/2026
**Estado:** Waves A-E implementadas/preparadas na branch; F desenhada. V3 LIVE nao foi tocado. Auditoria completa: `docs/audits/AUDIT-2026-09-20-NEXT-WAVE-V3.md`. ADR-0025.

**Feito (commits na branch):** `/app/comercial` guiado; CEP automatico (rota `/api/cep`, sem DDL, usa `customer_addresses`); importacao atomica (migration 20261004 + harness); fundacao IA provider-agnostic + metering (migration 20261005 + harness 62/62, `src/lib/ai-import`); Action Center (migration 20261006 + harness 55/55, `/app/atencao`, `src/lib/attention-rules.ts`); design de payout/snapshot.

**HUMAN GATES (nenhum foi cruzado):**
1. Aplicar LIVE, nesta ordem: `20261004_commercial_bulk_import_v1`, `20261005_ai_import_metering_v1`, `20261006_action_center_v1` (todas aditivas; harnesses rollback-only verdes; app ja funciona sem elas).
2. Cadastrar a chave Gemini e ligar `geminiMapper` num modulo servidor.
3. Autorizar o primeiro gasto/chamada paga e definir tarifa de creditos + tetos (lado plataforma).
4. Qualquer DDL financeiro/payout (onda F: vinculo usuario-grupo, snapshot V3 no `proposal_commercial_snapshots`, eventos de ledger). Decisoes do Owner pendentes: base da comissao (valor solicitado ou liberado), divisao em duas pernas, atribuicao usuario->grupo, empilhamento de gerente/supervisor.

**Nao feito de proposito:** UI de atribuicao de alerta (RPC pronta), sync agendado do Action Center, UI de revisao do mapeamento de IA (a biblioteca ja devolve o `ValidatedMapping`), indice unico do endereco primario.


## Independent ChatGPT verification — 20/09/2026

After Claude's report, ChatGPT independently reran all three rollback-only migration harnesses against the LIVE schema without persisting DDL or test data.

Results:
- `20261004_commercial_bulk_import_v1`: initially reproduced 1 failing harness assertion. Root cause was a **same-statement snapshot visibility artifact in the test**, not a migration defect: the assertion called the mutating RPC and selected its newly written row inside the same SQL statement. The production behavior was debugged and confirmed correct (`ok`, 1 row created, tenant organization correct). The harness was fixed by splitting the call and read into separate statements, commit `b2d5253a9439326b2f1ed4e31390b1519ae5977a`. Re-run: **ALL PASS (22 checks)**.
- `20261005_ai_import_metering_v1`: independent rollback-only re-run: **ALL PASS (62 checks)**.
- `20261006_action_center_v1`: independent rollback-only re-run: **ALL PASS (54 checks)**.

The final exception in each harness is the intentional rollback sentinel. No migration was applied LIVE and no synthetic test data persisted.

Human Gate remains unchanged: explicit Owner authorization is still required before applying 20261004, 20261005 and 20261006 LIVE.


## Next Wave V3 LIVE — 20/09/2026

Owner authorized and ChatGPT applied all three prepared migrations LIVE, in order:

- `20260920173825 commercial_bulk_import_v1`
- `20260920173830 ai_import_metering_v1`
- `20260920173835 action_center_v1`

**DO NOT REAPPLY.**

Verified on LIVE:
- bulk commercial import: 22/22 PASS rollback-only;
- AI import/metering: 62/62 PASS rollback-only;
- Action Center: 54/54 PASS rollback-only;
- 7 new persistent AI/attention tables checked with RLS=true;
- application SECURITY DEFINER inventory unchanged: 8 total (6 private + 2 public);
- Security Advisor: no WARN/ERROR, only 2 known platform-admin INFO;
- no synthetic rows persisted in mappings, AI limits/jobs/ledger/events, attention items/events;
- Performance Advisor has INFO only, currently 19 unindexed-FK candidates overall.

Correction for handoff: Action Center verified harness count is 54, not 55.

The next external gates are now Gemini secret + first paid call + pricing/limits. Wave F financial/payout work still requires Owner decisions and a separate DDL gate.


## Regra permanente de continuidade entre chats

Decisão do Owner: toda decisão relevante de produto, arquitetura, segurança, operação, Human Gate, migration LIVE e próximo passo deve ser registrada nos arquivos do projeto antes de depender do histórico do chat.

Objetivo: qualquer novo chat/IA deve conseguir retomar o Corban OS lendo o repositório, sem exigir que o Owner reconte o contexto.

Prática obrigatória:
- requisitos de produto -> documentação funcional/ADR correspondente;
- estado executável/LIVE -> `CORBAN-CURRENT-STATE.md`;
- próxima execução -> `.ai/CURRENT-TASK.md`;
- mudanças arquiteturais/invariantes -> ADR;
- migrations LIVE devem registrar versão real do Supabase e "DO NOT REAPPLY";
- nunca considerar uma decisão importante "salva" apenas porque apareceu no chat.


## Regra de economia de Claude — 20/09/2026

Owner pediu para preservar o limite semanal do Claude Code (restante informado: 29%, renovação sábado 09h).

Regra operacional a partir de agora:
- ChatGPT deve executar diretamente tudo que conseguir com as ferramentas conectadas (GitHub, Supabase, Vercel etc.).
- Só enviar tarefa ao Claude quando houver uma capacidade realmente necessária que o ChatGPT não possua, especialmente execução local complexa, ferramenta/plugin local ou diagnóstico que dependa do ambiente local.
- Não usar Claude como executor padrão nem como ponte entre IAs.
- Antes de pedir Claude, registrar exatamente por que a tarefa não pode ser concluída diretamente pelo ChatGPT.

## UX Comercial — execução direta pelo ChatGPT
Sem uso de Claude, foram preparados/implementados na branch:
- tela principal Comercial deixa de listar instituições, origens, convênios e grupos indefinidamente; mostra resumo + botão Gerenciar;
- páginas dedicadas: `/app/comercial/instituicoes`, `/app/comercial/origens`, `/app/comercial/convenios`, `/app/comercial/grupos`;
- gerenciadores permitem editar nome e inativar/reativar;
- Grupo de Comissão não pede mais “tipo” técnico ao usuário; o tipo fica oculto/technical-only;
- base do grupo virou uma escolha explicada por exemplos: % da comissão recebida ou % direto da operação;
- “Política de repasse” foi apresentada como **Regra padrão de comissão (opcional)**;
- importação CSV/XLSX das condições ganhou destaque como ação principal; modo manual ficou secundário;
- ações de cadastro/edição permanecem na página gerenciadora após salvar;
- nenhuma DDL nova e nenhum uso do Claude.


## Commercial UX consolidation — tables manager
- `/app/comercial` is now a compact dashboard instead of a long CRUD/list page.
- Product/Tables/Conditions moved to dedicated `/app/comercial/tabelas`.
- The table manager shows conditions in a compact grid and makes **Importar planilha** the primary path; manual condition entry is secondary/collapsible.
- CSV/XLSX bulk import remains atomic and uses the LIVE `import_commercial_conditions` RPC.
- No new DDL and no Claude usage.


## Empresa de origem — classificação editável
Decisão do Owner: a classificação de uma empresa de origem de terceiros não é definitiva no cadastro.

Exemplo:
- cadastrar inicialmente como Correspondente;
- depois corrigir para Promotora.

Regra de UX:
- o gerenciador de empresas de origem deve permitir editar **nome + classificação**;
- classificações atuais: Banco direto, Master, Promotora, Correspondente, Parceiro, Outro;
- editar a classificação não muda automaticamente a direção da relação comercial nem a origem da produção das tabelas;
- alterações históricas sensíveis devem continuar auditáveis quando houver vínculo financeiro/contratual.


## Grupo de vendedor como perfil comercial herdável
Correção conceitual do Owner a partir da operação real e do material 2Tech:

- **Grupo de vendedor** não é uma classificação de qualidade como Bronze/Prata/Ouro por padrão.
- No Corban OS, ele deve representar o **perfil comercial do vendedor/canal**, por exemplo:
  - Corretor;
  - Parceiro;
  - Afiliado;
  - Indicador;
  - outros grupos criados pelo tenant.
- No cadastro do vendedor deve existir um campo explícito para selecionar o grupo comercial ao qual ele pertence.
- Ao selecionar o grupo, o vendedor **herda automaticamente a regra de comissão configurada para aquele grupo**.
- A comissão padrão vem do grupo; exceções específicas podem existir, mas devem ser explícitas e auditáveis.
- O sistema não deve exigir que o usuário escolha novamente a mesma classificação em vários lugares.

Modelo funcional:
`Vendedor -> Grupo de Vendedor -> Regra de Comissão do Grupo -> Comissão efetiva conforme a tabela/condição`

Exemplo:
- Grupo: Corretor
- Regra do grupo: 65% da comissão recebida
- Vendedor João pertence ao grupo Corretor
- João herda automaticamente os 65%, salvo override explícito permitido pela política.

Distinção:
- Grupo de vendedor = perfil/canal comercial do vendedor;
- Regra de comissão = como esse grupo é remunerado;
- classificação adicional de performance (Bronze/Prata/Ouro etc.) pode existir futuramente como outra dimensão, mas não deve ser confundida com o grupo comercial principal.


## Vendedor — grupo comercial, grupo de comissão e categoria PF/PJ/SUB
Correção conceitual do Owner a partir das telas reais da 2Tech.

### 1. Grupo de Vendedores
É um cadastro livre do tenant. O tenant pode criar quantos grupos quiser; o exemplo da 2Tech mostra apenas "BÁSICO", mas isso não limita o conceito.

Exemplos possíveis no Corban OS:
- Corretor;
- Parceiro;
- Afiliado;
- Indicador;
- Time interno;
- qualquer outro grupo criado pela empresa.

No cadastro do vendedor existe um campo explícito **Grupo de Vendedor** que aponta para esse cadastro.

### 2. Grupo de Comissão
É outro vínculo, separado do Grupo de Vendedor.

No cadastro do vendedor também deve existir **Grupo de Comissão**.
Esse vínculo determina qual regra de comissão o vendedor herda quando a produção/condição correspondente é calculada.

Portanto:
`Vendedor -> Grupo de Vendedor`
e
`Vendedor -> Grupo de Comissão`
são relações distintas.

Não colapsar uma na outra.

### 3. Categoria PF / PJ / SUB
O cadastro do vendedor possui uma categoria operacional/comercial:
- PF;
- PJ;
- SUB;
- outros tipos futuros se necessário.

A categoria **SUB** tem impacto financeiro e não é mero rótulo.

Regra de negócio descrita pelo Owner:
- SUB 100%: quando a produção vem do banco/master, a comissão esperada para a empresa pode vir zerada, pois 100% do resultado pertence ao sub;
- SUB 90%: a produção deve registrar que a empresa espera reter 10% do total econômico daquela produção;
- de forma geral, o percentual do SUB determina a parcela do resultado destinada ao sub e, por diferença, a parcela esperada para a empresa.

Exemplo conceitual:
`base econômica 100% -> SUB 90% -> empresa espera 10%`.

Essa regra deve ser modelada separadamente da comissão de vendedor e da comissão recebida do banco, para não confundir:
- receita recebida da instituição;
- participação do SUB;
- comissão do vendedor/grupo;
- receita líquida/esperada da empresa.

### 4. Outras regras do cadastro
As telas da 2Tech mostram diversas flags e parâmetros no cadastro do vendedor, como:
- bloqueio de comissão no fechamento;
- comissão diferida;
- comissão bônus;
- permissão para cadastrar contrato;
- visualização de comissão de repasse;
- liberação sem físico;
- chamados;
- contrato com físico ausente;
- termo assinado;
- relatório de refinanciamento;
- custo de portabilidade;
- quantidade de dias para pendências/bloqueios/estornos;
- desconto de IR;
- valor mínimo para fechamento;
- desconto TED;
- dados Assertiva;
- observação.

Decisão: esses campos **não devem ser copiados automaticamente** para o Corban OS. Eles servem como evidência de que o vendedor pode ter políticas, permissões, SLAs e parâmetros financeiros/operacionais próprios. Cada regra deve ser avaliada antes de entrar no produto, agrupando por domínio em vez de criar uma tela monolítica.

### Direção de produto
O cadastro do vendedor deve ser modular, provavelmente por abas/seções:
- Dados básicos;
- Dados bancários;
- Vínculos comerciais;
- Comissão;
- Permissões;
- Regras operacionais;
- Contatos/documentos.

Evitar uma tela única com dezenas de toggles sem contexto.


## Fatores diários e fatores fixos por instituição
Requisito do Owner a partir da operação real e da tela 2Tech "Importar Fator Diário".

### Objetivo
O Corban OS precisa suportar bancos/instituições que trabalham com **fatores diários** e também instituições/produtos que usam **fatores fixos** até nova alteração.

Isso é necessário tanto para o módulo comercial quanto para o CRM, porque simulação, qualificação e oferta ao cliente dependem do fator vigente correto.

### Modelo funcional
Cada instituição/produto/convênio deve poder definir seu regime de fator:

1. **Fator diário**
   - usado por instituições como Daycoval;
   - pode variar por data/período, convênio, produto/tabela e tipo de contrato;
   - deve permitir importação em lote;
   - formatos prioritários: PDF e Excel/XLSX; CSV também pode ser aceito;
   - o sistema deve interpretar o arquivo, mostrar prévia, detectar alterações e só então publicar/ativar a nova versão;
   - histórico nunca deve ser apagado: nova carga gera versão/vigência nova;
   - deve ser possível consultar qual fator estava vigente em uma data passada.

2. **Fator fixo**
   - cadastro manual;
   - permanece vigente até uma alteração futura;
   - alteração cria nova vigência/versão em vez de sobrescrever o histórico;
   - pode ser definido por instituição + convênio + produto/tabela + tipo de contrato + prazo, conforme aplicável.

### Importação de fator diário
Fluxo desejado:
`Instituição -> Convênio -> Produto/Tabela (opcional conforme banco) -> Tipo de Contrato -> Período/data -> Arquivo -> Prévia -> Validar -> Publicar`

A tela deve permitir:
- selecionar instituição;
- selecionar convênio;
- opcionalmente limitar a produto/tabela;
- selecionar um ou mais tipos de contrato;
- informar data/período de vigência;
- enviar PDF/XLSX/CSV;
- visualizar fatores detectados;
- comparar com a versão atual;
- sinalizar linhas novas, alteradas, removidas/ausentes e conflitos;
- confirmar antes de tornar os fatores vigentes.

### PDF/Excel
A extração pode usar o mesmo princípio do importador comercial adaptativo:
- parser determinístico para estrutura/números;
- IA somente para mapear layout/semântica quando necessário;
- nenhum fator financeiro pode ser inventado;
- baixa confiança exige revisão humana;
- preservar arquivo original, fingerprint, mapeamento e linhagem.

### Integração com CRM
O CRM deve consultar automaticamente o fator vigente aplicável ao lead/cliente/proposta no momento da simulação.
A interface não deve exigir que o operador procure manualmente a planilha do banco quando houver fator válido no sistema.

### Relação com Tabelas/Condições
Fator é um domínio próprio, mas se relaciona com:
- Instituição;
- Convênio;
- Produto/Tabela;
- Tipo de Contrato;
- Prazo;
- Vigência.

Não confundir fator diário com:
- comissão recebida;
- regra de comissão;
- taxa nominal;
- coeficiente, embora possam coexistir na mesma condição comercial.

### UX
Criar no futuro uma área dedicada, provavelmente em:
`Cadastros/Comercial -> Fatores`
ou
`Operacional -> Importações -> Fatores`

Com duas ações claras:
- **Importar fatores diários**
- **Cadastrar fator fixo**

### Segurança e histórico
- nunca sobrescrever silenciosamente histórico;
- publicação deve ser versionada e auditável;
- importação deve ter prévia;
- alterações em massa devem ser atômicas;
- arquivo de origem deve permanecer vinculado à versão publicada.


## Tipo de Contrato como cadastro gerenciado em Produtos
Clarificação do Owner a partir da tela real da 2Tech.

Na arquitetura funcional de referência, **Tipo de Contrato** fica dentro do domínio de **Produtos** e possui gerenciamento próprio.

Exemplos mostrados:
- Antecipação de benefício;
- Ativação;
- Cartão C/ Saque;
- Cartão S/ Saque;
- Compra de Dívida;
- Conta Simples;
- Contrato Novo;
- Novo - Aumento Salarial;
- Portabilidade;
- Refin + Margem;
- e outros.

O cadastro não é apenas um nome. O tipo de contrato pode carregar flags funcionais como:
- habilitar na esteira de solicitação/digitação;
- habilitar para cadastro/busca de comissão;
- status ativo/inativo.

### Decisão para Corban OS
- **Tipo de Contrato** deve continuar sendo um catálogo reutilizável e independente de uma tabela específica.
- Porém, não deve ser tratado como lista fixa e invisível para sempre.
- Deve existir uma área de gerenciamento dentro de **Cadastros/Produtos**, onde perfis autorizados possam visualizar, habilitar/inativar e, conforme governança definida, criar/editar tipos.
- O tipo de contrato pode possuir capacidades/flags operacionais que controlam onde ele aparece no sistema.
- Não duplicar Tipo de Contrato em cada Produto/Tabela.
- Produto/Tabela referencia um Tipo de Contrato já cadastrado ao definir suas condições.

### UX sugerida
`Cadastros -> Produtos -> Tipos de Contrato`

Tela com:
- pesquisa;
- paginação;
- nome;
- uso na esteira;
- uso em comissão;
- status;
- visualizar/editar.

Essa decisão substitui a visão anterior de que bastaria manter somente quatro tipos comuns fixos e sem gerenciamento visível.


## Sincronização entre correspondentes / upstream-downstream
Requisito do Owner inspirado no funcionamento interno da 2Tech entre empresas que usam a mesma plataforma.

### Cenário real
Exemplo:
- Smart Promotora usa 2Tech;
- Hope usa 2Tech;
- Efetiva Mais usa 2Tech.

Como todas operam dentro da mesma plataforma, a 2Tech consegue associar cada empresa por identificador/chave interna e sincronizar dados entre a empresa que origina/repassa a produção e a empresa que recebe.

Exemplo de relação:
`Efetiva Mais -> repassa produção para Smart Promotora`

Quando a Efetiva atualiza a esteira/contrato, a Smart recebe a atualização correspondente sem trabalho manual.

### Escopo prioritário: esteira
A sincronização de esteira é considerada pelo Owner o caso mais simples e prioritário.

Modelo desejado:
- cada organização mantém sua própria visão/tenant;
- uma relação comercial upstream/downstream é cadastrada explicitamente;
- contratos/propostas compartilhados recebem um identificador de correlação entre as duas organizações;
- alterações de status relevantes no upstream propagam eventos para o downstream;
- o downstream vê a atualização em sua própria esteira;
- preservar origem, timestamps, evidência e histórico de cada atualização;
- não permitir que uma organização veja dados de outra fora das relações explicitamente autorizadas.

Possível fluxo:
`Upstream contract event -> correlation/external id -> integration event -> downstream proposal mirror/update -> audit trail`

### Tabelas de comissão vindas do upstream
Quando a empresa upstream repassa uma tabela comercial, o downstream deve receber apenas a **condição econômica que o upstream paga/repassa**.

Exemplo:
Efetiva Mais disponibiliza para Smart:
- contrato/tabela elegível;
- prazo/tipo;
- comissão que Efetiva paga à Smart;
- vigência e demais condições recebidas.

Isso **não deve sobrescrever nem transportar automaticamente**:
- grupos de comissão internos da Smart;
- regras de vendedor da Smart;
- percentuais pagos pela Smart a corretores/parceiros;
- política de repasse interna da Smart.

Portanto existem duas camadas:
1. **Condição upstream recebida** = quanto o fornecedor/master/correspondente paga para a Smart.
2. **Distribuição interna Smart** = quanto a Smart paga para seus grupos/vendedores, calculado localmente.

### Arquitetura conceitual
Separar:
- `ExternalOrganizationLink` / vínculo entre organizações;
- `ExternalContractReference` / correlação de proposta/contrato;
- `UpstreamCommercialOffer` / condição/tabela recebida;
- `LocalPayoutPolicy` / regras internas do tenant.

A condição upstream pode alimentar o cálculo da receita esperada da Smart, mas nunca deve ser confundida com a política interna de comissão.

### Quando as empresas não usam a mesma plataforma
O mesmo conceito deve funcionar por integração externa:
- API;
- webhook;
- importação;
- arquivo;
- conector específico.

A sincronização interna tenant-to-tenant é apenas o caso mais eficiente, não uma dependência estrutural.

### Regra de segurança
- vínculo sempre explícito e tenant-scoped;
- IDs externos não autorizam acesso por si só;
- mínimo compartilhamento necessário;
- eventos idempotentes;
- sem update destrutivo silencioso;
- divergências devem gerar caso de reconciliação/atenção.

### Prioridade
1. sincronização de esteira/status de contratos;
2. sincronização de condições/tabelas upstream;
3. apenas depois estudar automação mais profunda de comissionamento entre empresas.


## Importação de Produto/Tabela — componentes de comissão e repasses nomeados
Requisito refinado pelo Owner após análise da tela 2Tech e do arquivo real RelatorioProdutos.xls.

### Estrutura observada no arquivo real
O modelo possui, além dos dados do produto/tabela:
- Banco;
- Convênio;
- Tabela/Nome do Produto;
- Código no Banco;
- Vigência;
- Prazo inicial/final;
- Tipo de Contrato;
- Tipo de Formalização;
- Fator;
- Taxa a.m.;
- faixas de idade/valor/taxa.

A remuneração da **empresa** aparece decomposta em vários componentes:
- À Vista (Empresa);
- Bônus (Empresa);
- Diferido (Empresa);
- Bônus 2 % (Empresa);
- Bônus 3 % (Empresa);
- Plástico (Empresa);
- Seguro fixo (Empresa).

Depois existem até **5 conjuntos de repasse**, cada um repetindo os mesmos componentes:
- À Vista (Repasse N);
- Bônus (Repasse N);
- Diferido (Repasse N);
- Bônus 2 % (Repasse N);
- Bônus 3 % (Repasse N);
- Plástico (Repasse N);
- Seguro fixo (Repasse N).

O arquivo suporta valores percentuais e valores monetários, evidenciado por células com formato/símbolo de R$ em componentes como plástico/seguro.

### Problema de UX identificado
Rótulos genéricos como **Repasse 1, Repasse 2, Repasse 3...** são perigosos para o tenant.
Se a organização já possui os grupos de comissão configurados, uma coluna ordinal pode causar erro humano, por exemplo:
- comissão destinada a Corretor ser importada como Parceiro;
- Parceiro ser confundido com Indicador.

### Decisão para Corban OS
A exportação/modelo de importação deve ser **gerada dinamicamente a partir da configuração do tenant**.

Exemplo: se os grupos ativos forem:
- Corretor;
- Parceiro;
- Indicador;

o modelo deve gerar colunas semanticamente nomeadas, por exemplo:
- À Vista (Corretor);
- Bônus (Corretor);
- Diferido (Corretor);
- Plástico (Corretor);
- Seguro fixo (Corretor);
- À Vista (Parceiro);
- Bônus (Parceiro);
- ...;
- À Vista (Indicador);
- ...

Não usar "Repasse 1/2/3" como nomenclatura principal quando o sistema já conhece o grupo correspondente.

### Modelo financeiro
Separar explicitamente:
1. **Componentes recebidos pela empresa**
   - à vista;
   - diferido;
   - bônus 1/2/3;
   - plástico;
   - seguro fixo;
   - futuros componentes configuráveis.

2. **Componentes de repasse por grupo**
   - cada grupo pode receber valores diferentes por componente;
   - o repasse representa quanto a empresa paga àquele grupo/canal;
   - grupo de vendedor e grupo de comissão continuam vínculos distintos no cadastro do vendedor.

### Tipo do componente
Cada componente deve suportar sua unidade:
- percentual (%);
- valor fixo (R$).

Não inferir somente pelo nome.
No importador, a unidade deve ser validada explicitamente ou inferida apenas quando o arquivo traz evidência inequívoca (ex.: símbolo R$), sempre com prévia.

### Importador adaptativo
O Corban OS não deve depender de posição fixa de coluna.
Fluxo:
`arquivo -> leitura estrutural -> identificação semântica -> mapeamento para componentes/grupos -> prévia -> validação -> importação atômica`

O mapeamento deve:
- reconhecer nomes dos grupos do tenant;
- preservar colunas desconhecidas;
- detectar troca/ambiguidade entre grupos;
- impedir publicação se houver risco de mapear comissão para o grupo errado;
- permitir modelo Excel gerado pelo próprio Corban OS já com os nomes reais dos grupos.

### Regra importante
A tabela recebida de um upstream pode trazer **quanto o upstream paga para a empresa**, mas as colunas de repasse interno são responsabilidade do tenant.
Nunca transportar automaticamente regras internas de comissão de outra organização para o tenant downstream.


## Meta principal — importação inteligente com cálculo automático de repasses

Decisão central do Owner para o Corban OS:

O sistema deve eliminar o trabalho manual de passar horas atualizando tabelas e comissões.

### Cenário alvo
O usuário recebe uma planilha de um banco/master/origem, por exemplo HOPE, contendo:
- banco;
- convênio;
- produto/tabela;
- tipo de contrato;
- prazos;
- base de cálculo;
- comissão à vista;
- bônus;
- diferido;
- vigência;
- taxa;
- tipo de fator/fator;
- e outros componentes conforme o produto.

O usuário importa o arquivo e informa as regras locais da empresa, por exemplo:
- imposto: 6%;
- Corretores: 65%;
- Parceiro: 80%;
- Balcão: 50%.

A partir daí o Corban OS deve:
1. interpretar o arquivo;
2. cadastrar/atualizar automaticamente tabelas, prazos, vigências, taxas, fatores e componentes recebidos;
3. identificar quais componentes existem de fato no arquivo;
4. aplicar as regras locais já cadastradas para os grupos;
5. perguntar ao usuário apenas o que realmente for necessário quando surgir um componente novo ou opcional.

### Perguntas condicionais
Se o arquivo tiver **Diferido > 0**, perguntar algo como:
- "Deseja repassar comissão diferida?"
- se sim, para quais grupos e em qual percentual/regra?

Se houver **Plástico**, perguntar:
- se esse componente entra no repasse;
- para quais grupos;
- se o repasse é em % ou R$, conforme o componente.

Mesma lógica para:
- Bônus;
- Bônus 2;
- Bônus 3;
- Seguro fixo;
- outros componentes futuros.

Se o componente não existir no arquivo, não perguntar sobre ele.

### Regras por convênio
As políticas não são necessariamente universais.
O sistema deve aceitar regras em camadas:
1. padrão da organização;
2. override por banco/instituição;
3. override por convênio;
4. override por produto/tabela;
5. exceção explícita por condição, se necessário.

A regra mais específica prevalece, sempre com rastreabilidade.

Exemplo:
- padrão Smart: imposto 6%, Corretor 65%, Parceiro 80%, Balcão 50%;
- Governo do Acre pode ter regra diferente;
- outro convênio pode não repassar Diferido;
- produto cartão pode ter regra específica para Plástico/Seguro.

### Princípio de UX
O usuário não deve preencher centenas de células manualmente.

Fluxo desejado:
`Upload -> leitura automática -> reconhecimento de componentes -> aplicação das regras conhecidas -> perguntas somente sobre ambiguidades/novos componentes -> prévia completa -> confirmar -> importação atômica`

### Exemplo com arquivo HOPE analisado em 20/09/2026
O arquivo `RelatorioMelhorComissao.xls` possui:
- Banco: HOPE;
- Convênio: Gov. AC;
- Produto;
- Tipo de Contrato;
- Prazo Inicial/Final;
- Base Cálculo À Vista/Bônus/Diferido;
- À Vista;
- Bônus;
- Diferido;
- Ativação Imediata;
- vigência;
- TAXA a.m.;
- Tipo Fator;
- Fator.

No arquivo analisado, os valores de **Bônus** e **Diferido** estão zerados em todas as linhas, portanto o sistema não deveria perguntar sobre repasse desses componentes nessa importação.

O arquivo traz `Tipo Fator = DIÁRIO`, o que também deve alimentar a configuração de fator aplicável sem exigir recadastro manual.

### Motor de cálculo
Separar:
- componente recebido do upstream;
- base bruta/líquida;
- imposto/desconto;
- regra de repasse do grupo;
- componente repassado;
- receita esperada da empresa.

Exemplo simplificado:
`comissão recebida -> base após imposto -> regra do grupo -> repasse -> retenção/receita esperada`

Todos os cálculos financeiros devem ser determinísticos, versionados e auditáveis. IA pode mapear a planilha, mas não deve inventar percentuais nem executar cálculo financeiro fora das regras determinísticas.

### Objetivo final
O Corban OS deve transformar atualização de tabela/comissão de uma tarefa manual de horas em um fluxo de poucos minutos, com revisão humana apenas onde houver novidade, ambiguidade ou regra ainda não cadastrada.


## Estrutura macro do ecossistema Corban
Correção do Owner:

A estrutura conceitual final deve ser entendida como:

```text
CORBAN
├── SmartMatch
└── DeskcommCRM
```

### CORBAN
É a camada/ecossistema principal, o sistema operacional do correspondente bancário.

### SmartMatch
É um módulo/produto dentro do ecossistema Corban, voltado para aquisição, atendimento, qualificação, recuperação e medição de receita/leads.

### DeskcommCRM
Também faz parte da estrutura maior do Corban como frente/módulo de CRM e comunicação/operação comercial, ainda que possa continuar existindo tecnicamente como projeto/repositório separado durante o desenvolvimento.

### Regra arquitetural
- Corban é o guarda-chuva principal.
- SmartMatch e DeskcommCRM não devem ser tratados como projetos totalmente desconectados do ponto de vista de produto.
- Integrações entre eles devem ser feitas por contratos claros (APIs/eventos/identidades), sem acoplamento inseguro de banco ou secrets.
- Cada componente pode manter infraestrutura/repositório independente enquanto a arquitetura de produto converge sob Corban.


## Execução protocolada — 20/09/2026
Owner reafirmou:
- tripla revisão obrigatória antes de execução relevante;
- manter handoff atualizado para qualquer novo chat/IA;
- ChatGPT executa diretamente tudo que puder;
- Claude somente quando necessário, sempre com fila longa e instrução explícita de economia de tokens/ferramentas locais.

Primeira onda escolhida após tripla revisão: reorganização de navegação/UX sem DDL e sem alteração de dados.


## Auditoria pré-Wave B — schema LIVE
Leitura somente, sem DDL:
- já existem `commercial_entities`, `commercial_relationships`, `commercial_channels`, `network_split_rule_versions`, `channel_commission_rule_versions` e `commission_rule_components`;
- `commission_rule_components` já suporta percentual, valor fixo e fator de antecipação;
- `network_split_rule_versions` já suporta splits como 100/0 e 90/10 por relação/banco/tabela/componente;
- `commission_groups` e V3 comercial já existem;
- não foi encontrada uma entidade explícita de vendedor/perfil comercial vinculando vendedor -> grupo de vendedor -> grupo de comissão;
- não foi encontrada estrutura dedicada de fatores diários/fixos versionados;
- portanto a próxima onda deve **reutilizar** rede/split/componentes existentes e adicionar apenas as lacunas, evitando duplicação.

Próximo passo executável sem Claude: desenhar e preparar migration aditiva para cadastro de vendedor/perfil comercial + vínculo de grupos + categoria PF/PJ/SUB e fator versionado. Não aplicar LIVE sem Human Gate explícito.


## Human Gate — Seller/Sub + Fatores LIVE
Preparado e validado rollback-only:
- `20261007_seller_commercial_profile_v1.sql`
- `20261008_commercial_factors_v1.sql`

Validação:
- ambos executaram em transação com seus contratos SQL e ROLLBACK sem erro;
- nenhum objeto ficou persistido no LIVE;
- Vercel build dos commits ficou READY;
- não foi usado Claude.

Onda 20261007:
- Grupo de Vendedor separado de Grupo de Comissão;
- vendedor PF/PJ/SUB;
- SUB com regra econômica versionada e publicada por RPC;
- leitura de CPF/CNPJ fail-closed para supervisor+.

Onda 20261008:
- fatores fixos e diários;
- lotes versionados por data/revisão;
- faixas de prazo;
- vínculo opcional ao import_batch para linhagem de PDF/XLSX/CSV;
- publicação governada;
- resolver determinístico para CRM/simulação.

Próxima ação exige Human Gate explícito: aplicar as duas migrations LIVE. Depois do apply, executar contratos, advisors, criar UI de Vendedores/Grupos e Fatores e continuar para importação inteligente.


## Pós-LIVE Seller/SUB + Fatores
LIVE confirmado:
- `20260920235725 seller_commercial_profile_v1`
- `20260920235731 commercial_factors_v1`

Contratos pós-apply passaram. Security advisor sem WARN/ERROR novo.

Implementação de aplicação já iniciada sem Claude:
- Vendedores: Grupo de Vendedor separado de Grupo de Comissão, PF/PJ/SUB, edição, ativação e publicação de regra SUB;
- Fatores: perfil diário/fixo, cadastro manual, CSV/XLSX determinístico, publicação versionada;
- Cadastros hub atualizado.

Próxima fila:
1. confirmar build Vercel do commit de UI;
2. preparar extensão de componentes de comissão para à vista/diferido/bônus/plástico/seguro e importador guiado;
3. preparar gerenciamento de Tipo de Contrato no domínio Produtos sem quebrar os tipos globais existentes;
4. gerar modelo de importação com nomes reais dos grupos de comissão;
5. só então solicitar novo Human Gate para o DDL adicional.


## Human Gate — Componentes de comissão + Tipos de Contrato + índices
Preparado e validado rollback-only:
- `20261009_component_commissions_v1.sql`
- `20261010_tenant_contract_types_v1.sql`
- `20261011_post_seller_factors_fk_indexes_v1.sql`

Tripla revisão concluída:
1. completude: cobre componentes À Vista/Diferido/Bônus 1/2/3/Plástico/Seguro, % ou R$, regra por Grupo de Comissão, desconto/imposto e escopo organização/instituição/convênio/tabela;
2. adversarial: camada aditiva, sem reescrever motor simples; política financeira fail-closed supervisor+; escopo de tabela validado contra rota; tipos globais preservados;
3. execução: três migrations + contratos SQL executados dentro de transação com ROLLBACK e passaram sem persistência.

`20261010` mantém os tipos globais e permite tipos próprios do tenant, além de configuração habilitado/esteira/comissão.

`20261011` apenas adiciona índices para FKs de Seller/SUB/Fatores apontadas pelo advisor.

Próxima ação exige autorização explícita para DDL LIVE. Depois do apply:
- rodar contratos e advisors;
- construir UI Produtos -> Tipos de Contrato;
- construir política de componentes e importador inteligente;
- gerar XLSX com nomes reais dos Grupos de Comissão;
- implementar perguntas condicionais para Diferido/Plástico/Bônus;
- não usar Claude salvo necessidade real.


## Pós-LIVE Componentes + Tipos de Contrato
LIVE confirmado:
- `component_commissions_v1`
- `tenant_contract_types_v1`
- `post_seller_factors_fk_indexes_v1`

`Refin/Portabilidade` foi incluído como Tipo de Contrato global para refinanciamento da portabilidade.

Contratos pós-apply passaram e security advisor não trouxe WARN/ERROR novo.

Código já iniciado:
- `/app/comercial/tipos-contrato`;
- `/app/comercial/regras-comissao`;
- Central de Cadastros atualizada.

Fila autônoma atual:
1. validar build Vercel das novas UIs;
2. respeitar flags de Tipo de Contrato em telas de tabela/simulação;
3. gerar modelo XLSX com nomes reais dos Grupos de Comissão;
4. construir parser component-aware para planilhas HOPE/2Tech-style;
5. preparar RPC atômica de importação inteligente (não aplicar LIVE sem novo gate).


## Human Gate — Smart Commercial Import V1
Preparado e validado rollback-only:
- `20261012_smart_commercial_import_v1.sql`
- contrato SQL correspondente.

A migration cria:
- vínculo condição -> versão da política component-aware;
- RPC atômica `import_smart_commercial_rows`;
- criação/localização automática de Instituição, Convênio, rota e Produto/Tabela;
- uso/criação de versão rascunho;
- upsert de condição por Tipo de Contrato + prazo;
- componentes recebidos;
- vínculo da regra interna;
- fator daily/fixed quando presente;
- nada publica a Tabela automaticamente.

Parser determinístico adicionado em `src/lib/imports/smart-commercial.ts`:
- reconhece planilhas HOPE/2Tech-style em XLSX/CSV;
- expande faixa de prazo;
- reconhece Refin/Portabilidade;
- zero em Diferido/Bônus não gera falsa necessidade;
- Plástico sem unidade explícita é recusado;
- Repasse 1/2/3 é recusado como ambíguo, nunca associado silenciosamente a um grupo;
- nomes reais de Grupo de Comissão são reconhecidos.

Modelo XLSX dinâmico já disponível no código:
- gera colunas com nomes reais dos grupos;
- inclui componentes da empresa e regras/unidades por grupo;
- respeita Tipos de Contrato habilitados.

Próxima ação que altera produção: aplicar `20261012_smart_commercial_import_v1` LIVE.
Depois: montar UI de prévia/perguntas condicionais/aplicar e então usar Claude apenas para a etapa local de XLS legado/PDF + testes locais extensos, se ainda necessária.


## Smart Import UI implementada
Após o LIVE de `smart_commercial_import_v1`, foi criada a experiência guiada:
- upload CSV/XLSX;
- análise sem gravação;
- resumo de linhas/tabelas/componentes;
- amostra das condições;
- perguntas somente quando Diferido/Plástico/Bônus aparecem;
- confirmação para ignorar Repasse 1/2/3 legado;
- seleção da política component-aware;
- importação atômica;
- rascunho obrigatório antes da publicação.

Também existe `/api/comercial/modelo`, gerando XLSX com nomes reais dos Grupos de Comissão.

Próxima fila autônoma:
1. validar o build Vercel do fluxo guiado;
2. corrigir qualquer erro de compilação;
3. acrescentar comparação prévia entre componente recebido e política interna (empresa recebe / grupo recebe / empresa retém);
4. avaliar suporte XLS legado/PDF. Se exigir execução local/biblioteca/testes com arquivo real, acionar Claude em uma única tarefa longa, instruído a economizar contexto e usar as ferramentas já instaladas.


## Próxima etapa requer Claude local
ChatGPT esgotou o que é seguro executar diretamente nesta onda.

Motivo real para Claude:
- o suporte a `.xls` legado e PDF provavelmente exige nova dependência npm;
- é necessário gerar/validar `package-lock.json` via npm real, não manualmente;
- precisamos testar contra arquivos reais locais HOPE/2Tech;
- precisamos rodar `npm test`, `npm run build` e lint localmente antes de publicar;
- ChatGPT não possui checkout local autenticado do repo nem deve fabricar lockfile.

Estado antes do handoff:
- branch `architecture/corban-os-master-v2`;
- Vercel produção `READY`;
- Smart Import CSV/XLSX LIVE;
- migration `smart_commercial_import_v1` LIVE;
- nenhuma DDL pendente imediata;
- Claude deve trabalhar somente em branch própria derivada da branch atual e não tocar main;
- usar ferramentas/plugins locais já instalados e leitura seletiva para economizar tokens.

## Smart Import: XLS legado + PDF (Claude local) - 20/09/2026
**Branch:** `feature/smart-import-xls-pdf` (derivada de `architecture/corban-os-master-v2`; main intocada). Sem DDL, sem secret, sem gasto.

**Feito:** `smart-file.ts` (leitor unico por conteudo), `legacy-xls.ts` (@e965/xlsx), `smart-pdf.ts` (unpdf + geometria deterministica, recusa quando ambiguo), `file-guards.ts` (zip/nome/magic bytes); teto de linhas no XLSX (antes cortava em 1.000 em silencio); fator DIARIO exige data; Fator 0 = sem fator; coluna de dinheiro desconhecida recusa; slots Repasse 1..N listados e nunca mapeados. Validado com HOPE real (54 condicoes, 5 slots de repasse ignorados) e relatorio 2Tech real. Detalhes: `docs/SMART-COMMERCIAL-IMPORT-V1.md`.

**Testes:** unit 329/329, tsc, eslint, build verdes. (4 testes de UI estavam desatualizados desde a reformulacao da navegacao e o teste do parser smart nem rodava por causa do alias `@/`; corrigidos.)

**Falta / follow-ups:** UI mostrar `needsReview` do PDF com CTA de mapeamento manual; deteccao de formato `%` tambem no XLSX; OCR/IA para PDF escaneado (exige gate de custo/secret); auditar visibilidade de comissao nas novas paginas de `/app/comercial/*` (as assercoes antigas de `canViewCommission` na pagina principal foram removidas porque a pagina foi reescrita).

**Human Gate:** nenhum. Proximo passo sugerido: revisar e mesclar `feature/smart-import-xls-pdf` em `architecture/corban-os-master-v2`.


## Pós-merge Smart Import XLS/PDF
Revisão independente concluída:
- PR #1 mesclado na branch arquitetural;
- branch estava 2 commits à frente e 0 atrás, sem DDL;
- merge e correção de visibilidade passaram no build Vercel;
- produção está READY no commit `fbca952839551254dc0990a8b969e476934ed191`.

Achado de segurança/arquitetura corrigido:
- `/app/comercial` voltou a obedecer a política central `canViewCommission`;
- comportamento atual continua supervisor+;
- decisão futura de visibilidade permanece centralizada em RBAC + RLS.

Próxima fila:
1. testar fluxo com um XLS/PDF comercial real quando houver amostra sem dados pessoais;
2. adicionar mapeamento manual para arquivos que retornem “Necessita revisão/mapeamento”;
3. resolver formatação percentual de XLSX de forma determinística;
4. depois retomar preview econômico empresa recebe / grupo recebe / empresa retém, sem delegar cálculo à IA.


## XLSX percentual fechado
A limitação registrada pelo Claude sobre percentual formatado em XLSX foi tratada diretamente pelo ChatGPT:
- ExcelJS agora detecta numFmt com `%` no Smart Import;
- a carga é recusada como ambígua, em vez de interpretar `0.15` como `0,15%` ou `15%`;
- comportamento do importador legado fora do Smart Import não foi alterado;
- build Vercel READY no commit `8277790fe548ed1532ac5a56b6a3fe9ebb6f3da8`.

Próxima fila permanece:
1. mapeamento manual para arquivos que exigem revisão;
2. preview econômico determinístico;
3. teste com XLS/PDF comercial real quando houver amostra adequada.


## Smart Import — estado após prévia econômica/mapeamento
Concluído diretamente pelo ChatGPT:
- prévia financeira component-aware usando a versão selecionada da política;
- cálculo determinístico sem IA/float;
- empresa recebe / após imposto / grupo recebe / empresa retém;
- mapeamento manual de cabeçalhos para arquivos com nomenclatura externa;
- preview/apply compartilham exatamente o mesmo header_map;
- mapeamento inválido falha fechado;
- upload agora descreve corretamente CSV/XLSX/XLS/PDF;
- Vercel READY.

Próxima fila autônoma:
1. mapear valores de Tipo de Contrato desconhecidos (ex.: “Refin-Portabilidade” → “Refin/Portabilidade”) sem criar tipo silenciosamente;
2. sugerir automaticamente regra de comissão por escopo de Instituição/Convênio/Tabela, mas exigir escolha quando houver ambiguidade;
3. depois comparar Repasse 1/2/3 externo com política interna somente quando o usuário mapear explicitamente o slot ao grupo — nunca inferir.


## Human Gate atual — policy scope DB guard
Antes do gate, concluído:
- mapeamento explícito de valor de Tipo de Contrato externo → tipo existente/habilitado;
- app-layer policy-scope validation em preview e apply;
- Vercel READY;
- migration `20261013_smart_import_policy_scope_guard_v1.sql` validada rollback-only;
- zero vínculos LIVE incompatíveis detectados;
- migration ainda não consta em `list_migrations`.

Próxima ação irreversível/produção:
**aplicar `20261013_smart_import_policy_scope_guard_v1` LIVE**.

Depois do apply:
1. rodar contract pós-apply;
2. rodar Security Advisor;
3. persistir versão da migration LIVE;
4. continuar política sugerida automática e comparação explícita de Repasse 1/2/3.


## Policy scope guard LIVE
`smart_import_policy_scope_guard_v1` foi aplicada LIVE como versão `20260921021027`.
Contract pós-apply passou e Security Advisor não apresentou WARN/ERROR novo.
**NÃO REAPLICAR.**

Fila autônoma retomada:
1. sugestão determinística de regra de comissão pelo escopo mais específico;
2. exigir escolha humana quando houver empate/ambiguidade;
3. mapeamento explícito de Repasse 1/2/3 para Grupo de Comissão somente para comparação/validação, nunca por inferência.


## Smart Import — repasses externos comparados
Concluído:
- mapeamento explícito de Repasse 1/2/3 para Grupo de Comissão;
- semântica e unidade obrigatórias;
- comparação determinística do repasse externo contra a política interna;
- nenhuma divergência altera regra financeira automaticamente;
- sugestão determinística da política mais específica já ativa;
- Vercel READY no commit `f165112f4e8aa1370d193c83e3b4b0b4bad4a4f6`.

Próxima fronteira arquitetural:
integrar o Vendedor/SUB à proposta e ao cálculo esperado, congelando seller/group/category e a versão da regra SUB usada por componente. Hoje o cadastro SUB existe e está LIVE, mas a proposta/financeiro ainda não congela nem aplica essa regra.


## Human Gate atual — Seller/SUB proposal snapshot
Preparado e validado rollback-only:
- `supabase/migrations/20261014_seller_sub_proposal_snapshot_v1.sql`
- `tests/security/seller-sub-proposal-snapshot-contract.sql`
- `docs/SELLER-SUB-PROPOSAL-SNAPSHOT-V1.md`

Definition of Done do DDL:
- seller atribuído somente em draft via RPC supervisor+;
- seller congela antes do financeiro;
- SUB resolve regra publicada por componente/fallback all;
- company share fica congelado por componente;
- expected commission usa company share congelado;
- non-SUB/legado preserva 100%;
- comissão de grupo não vaza em attribution snapshot member-visible;
- network split não é confundido com SUB;
- migration/contract rollback-only verde.

LIVE atual sem propostas/eventos/SUB reais, reduzindo risco de backfill.
Próxima ação: aplicar migration LIVE somente após autorização explícita.
Depois do LIVE: construir seletor de vendedor na proposta draft e exibir snapshot SUB/receita esperada supervisor+.


## HANDOFF PARA NOVO CHAT — 20/09/2026
Sessão encerrada por limite de contexto. Handoff consolidado criado em `.ai/NEXT-CHAT-HANDOFF.md`.

Próximo chat deve retomar pelo Human Gate de `20261014_seller_sub_proposal_snapshot_v1.sql`, sem reexecutar migrations LIVE anteriores.


## Seller/SUB proposal snapshot — LIVE
- Autorização recebida e `seller_sub_proposal_snapshot_v1` aplicada LIVE como `20260921025320`.
- Contract pós-apply passou sem exceções.
- Security Advisor sem WARN/ERROR novo; permanecem apenas 2 INFO históricos de Platform Admin.
- `assign_proposal_seller` está governada e disponível apenas para authenticated, com RBAC supervisor+ dentro da função/app.
- Proposal component snapshot congela seller, regra SUB e company share por componente.
- `publish_expected_commission` usa o company share congelado; histórico já congelado não é reescrito.
- UI de proposta draft ganhou seletor de vendedor/SUB usando a RPC governada; commission group não é exposto nessa tela.

Próximo passo autônomo:
1. confirmar Vercel READY do seletor de vendedor;
2. revisar se a rota comercial/freeze já tem UI completa para seller/SUB ou se falta somente apresentação do snapshot supervisor+;
3. seguir apenas até o próximo DDL/Human Gate real.


## Fluxo Seller/SUB + rota comercial — aplicação concluída
- seletor de Vendedor/SUB em proposta draft está integrado à RPC governada;
- snapshot SUB/empresa por componente aparece somente para perfis com `canViewCommission`;
- card de congelamento de rota comercial foi adicionado; o canal é derivado da regra escolhida para impedir combinação manual regra/canal inválida;
- server action de freeze valida UUID, RBAC supervisor+, regra publicada e vigência também no app;
- publicação de comissão esperada usa feedback sanitizado e fica oculta quando já existe `commission_expected`;
- consulta de `financial_events` deixou de ser feita para perfis sem visibilidade de comissão;
- Vercel READY no commit funcional `97bf2548f360429a2f52c66af385295d04e5ba06`;
- validação do percentual SUB no app foi alterada para parsing decimal por string, sem `float`.

## Human Gate atual — Proposal/Financial integrity hardening V1
Preparada e **NÃO LIVE**:
- `supabase/migrations/20261015_proposal_financial_integrity_hardening_v1.sql`;
- `tests/security/proposal-financial-integrity-hardening-contract.sql`.

Achados adversariais corrigidos no pacote preparado:
1. `freeze_proposal_commercial_route` hoje exige status published, mas no LIVE ainda não valida `effective_from/effective_until` no próprio banco; a nova versão falha fechado fora da vigência;
2. `publish_expected_commission` passa a atualizar/criar a conciliação de cada componente imediatamente;
3. `publish_financial_evidence_event` passa a atualizar conciliação também quando usado diretamente para comissão reportada/pagamento recebido;
4. UPDATE/DELETE desnecessários são revogados das tabelas imutáveis de snapshot comercial para authenticated/anon.

Validação:
- migration + contract passaram juntos em `BEGIN -> testes -> ROLLBACK`;
- nenhuma alteração do pacote ficou persistida;
- `list_migrations` confirma que `proposal_financial_integrity_hardening_v1` ainda NÃO está LIVE;
- precheck LIVE continua com 0 propostas, 0 snapshots, 0 eventos financeiros e 0 casos de conciliação;
- Security Advisor continua sem WARN/ERROR novo; somente 2 INFO históricos de Platform Admin.

**Próxima ação requer autorização explícita do Owner para aplicar `20261015_proposal_financial_integrity_hardening_v1` LIVE.**


## Proposal/Financial integrity hardening V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921031621 proposal_financial_integrity_hardening_v1`.
- Contract pós-apply passou no banco real.
- `freeze_proposal_commercial_route` agora exige regra publicada e dentro de `effective_from/effective_until` também no banco.
- `publish_expected_commission` refresca a conciliação por componente após publicação/idempotência.
- `publish_financial_evidence_event` refresca conciliação em `commission_reported` e `payment_received`.
- authenticated/anon não possuem mais UPDATE/DELETE nos snapshots comerciais imutáveis.
- Security Advisor segue sem WARN/ERROR novo; permanecem somente 2 INFO históricos de Platform Admin.
- A camada de aplicação financeira também deixou de usar ponto flutuante na validação de reversão e na decisão de saldo reversível.


## Simulation lifecycle — próxima Human Gate
Revisão pós-financeiro encontrou um P1 real ainda aberto:
- a aplicação/banco reconhecem `calculated`, `selected`, `expired`, `cancelled`;
- existe write guard, mas não existia RPC governada para encerrar uma simulação calculada;
- o guard anterior ainda permitia transição de `selected` para `expired/cancelled`, o que pode conflitar com uma proposta já criada.

Corrigido sem DDL LIVE:
- parsing de valor de simulação deixou de usar `Number()` e usa decimal determinístico;
- exibição monetária de simulações usa `formatBRL` sem float;
- builds dessas correções estão READY no Vercel.

Preparado e **NÃO LIVE**:
- `supabase/migrations/20261016_simulation_lifecycle_v1.sql`;
- `tests/security/simulation-lifecycle-contract.sql`.

Modelo preparado:
- `close_simulation(id,target)` aceita somente `cancelled` ou `expired`;
- somente simulação `calculated` pode ser encerrada;
- supervisor/manager/admin apenas (fail-closed nesta primeira versão);
- simulação que já tenha proposta é recusada;
- `selected` passa a ser terminal e não pode virar cancelled/expired;
- terminal `expired/cancelled` permanece imutável;
- anon sem EXECUTE; authenticated chama RPC, e RBAC é conferido dentro dela.

Validação:
- migration + contract passaram em `BEGIN -> testes -> ROLLBACK`;
- migration não consta em `list_migrations`;
- Security Advisor continua sem WARN/ERROR novo; somente 2 INFO históricos de Platform Admin.

**Próxima ação irreversível: aplicar `20261016_simulation_lifecycle_v1` LIVE após autorização explícita.**


## Simulation lifecycle V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921032402 simulation_lifecycle_v1`.
- Contract pós-apply passou no banco real.
- `selected` agora é terminal; `expired/cancelled` continuam terminais.
- Encerramento governado aceita somente `calculated -> cancelled|expired`, supervisor/manager/admin, e recusa simulação com proposta vinculada.
- UI concluída: supervisor+ vê ações Cancelar/Expirar apenas em `calculated`; simulações terminais não oferecem Criar proposta.
- Vercel READY no commit funcional `ac367bdf97f8cfd6a933b2ec3ebab1bd873b4c8d`.

## Human Gate atual — Organization direct-write privilege hardening V1
Achado confirmado no LIVE:
- `authenticated` ainda possui INSERT/UPDATE/DELETE em `public.organizations`;
- não há dependência funcional legítima dessa escrita direta na aplicação;
- criação de organização é fluxo Platform Admin via Admin client + `bootstrap_organization_admin`;
- tenant comum precisa apenas de SELECT governado por RLS.

Preparado e **NÃO LIVE**:
- `supabase/migrations/20261017_organization_direct_write_privilege_hardening_v1.sql`;
- `tests/security/organization-direct-write-privilege-contract.sql`.

O pacote:
- revoga INSERT/UPDATE/DELETE de `authenticated` e `anon` em `organizations`;
- preserva SELECT de authenticated;
- verifica que authenticated continua sem EXECUTE em `bootstrap_organization_admin`.

Validação:
- migration + contract passaram em `BEGIN -> testes -> ROLLBACK`;
- `20261017_organization_direct_write_privilege_hardening_v1` não consta em `list_migrations`;
- Security Advisor continua sem WARN/ERROR novo; apenas 2 INFO históricos de Platform Admin.

**Próxima ação requer autorização explícita para aplicar `20261017_organization_direct_write_privilege_hardening_v1` LIVE.**


## Organization direct-write privilege hardening V1 — LIVE
- Autorização explícita recebida e migration aplicada LIVE como `20260921033720 organization_direct_write_privilege_hardening_v1`.
- Contract pós-apply passou no banco real.
- `authenticated` e `anon` não possuem mais INSERT/UPDATE/DELETE em `public.organizations`.
- SELECT de `authenticated` foi preservado.
- `authenticated` continua sem EXECUTE em `bootstrap_organization_admin`.
- Security Advisor continua sem WARN/ERROR novo; permanecem apenas 2 INFO históricos de Platform Admin.

## Próxima decisão de produto/segurança — visibilidade de comissão para agente
Estado verificado:
- UI centraliza visibilidade em `canViewCommission` e hoje é supervisor+;
- porém `authenticated` ainda tem SELECT de tabela inteira em `simulations` e `proposals_v2`;
- assim, `expected_commission_amount` continua tecnicamente legível por um membro autenticado via API, mesmo quando a UI não exibe;
- resolver corretamente não é uma simples revogação de coluna porque RPCs security-invoker existentes leem essas tabelas e podem depender dos grants atuais.

**Nenhuma migration foi criada para isso ainda.** Antes de alterar o contrato de acesso, o Owner precisa decidir se agentes devem ser impedidos também no nível da API de ler comissão esperada. A política atual da UI sugere SIM, mas a decisão de produto deve ser explícita.
