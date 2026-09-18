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
