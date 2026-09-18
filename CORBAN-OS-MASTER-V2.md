# CORBAN OS — MASTER V2

**Status:** arquitetura alvo consolidada  
**Data:** 17/09/2026  
**Papel:** fonte de verdade conceitual do Corban OS. O estado implementado é registrado separadamente em `CORBAN-CURRENT-STATE.md`.

## 1. Visão

Corban OS é um SaaS multi-tenant, multi-brand e white-label para correspondentes bancários. O objetivo é controlar o ciclo completo de receita e operação: aquisição recebida, cliente, oportunidade, simulação, proposta, documentos, digitação, esteira, produção, contrato, comissão, conciliação, repasses, metas, financeiro, gestão, integrações, automações, IA e auditoria.

O produto deve crescer sem reconstruir o núcleo. Segurança, isolamento, rastreabilidade e integridade financeira não podem ser sacrificados para acelerar entregas.

## 2. Fronteiras do ecossistema

- **Corban OS:** fonte de verdade da operação bancária e financeira do correspondente.
- **Growth OS:** aquisição, mídia, experimentação, tracking e atribuição.
- **SmartMatch:** conversão, atendimento, qualificação, follow-up e recuperação.
- **Cérebro / Control Tower:** coordenação dos projetos, agentes e execução.

A integração ocorre por APIs, eventos e contratos versionados. Um produto não acessa diretamente o banco de dados privado de outro.

## 3. Platform Core

O núcleo compartilhado contém Organization/Tenant, Identity, Membership, RBAC/ABAC, Teams, Plans, Billing, Entitlements, Brands, Domains, Feature Flags, Audit, Security e Connector Hub.

**Tenant é fronteira de segurança. Brand é identidade visual/comercial.** Uma organização pode futuramente possuir múltiplas marcas sem criar falsos tenants.

## 4. Rede comercial e gestão

Hierarquia suportada: Diretor → Gerente Regional → Supervisor → Vendedor → Corretor/Parceiro, com escopos configuráveis. O sistema mede carteira, leads, contatos, oportunidades, simulações, propostas, contratos, produção, comissão, SLA, follow-ups e resultados por indivíduo/equipe/unidade/região.

## 5. Customer 360 e CRM

Customer é a pessoa canônica. Opportunity representa interesse comercial. Campaign e Attribution representam aquisição. Owner/Agent/Broker representa responsabilidade comercial.

A origem original do Customer nunca é sobrescrita pela origem de uma nova oportunidade. O mesmo cliente pode ter várias oportunidades.

Customer 360 reúne identidade, contatos, endereço, dados bancários, múltiplas contas, múltiplas chaves PIX, documentos, oportunidades, propostas, contratos, comunicações, tarefas, agenda e timeline.

Dados atuais do cliente não alteram evidências históricas: proposta e contrato guardam snapshots relevantes.

## 6. Produtos, bancos, Masters e tabelas

Catálogo: Bank → Provider/Master → Agreement → Product → Modality → ProductTable → ProductTableVersion.

Banco/produto/convênio são conceitos de plataforma; habilitação, rota, credenciais e condições comerciais podem ser específicas por organização.

Tabela publicada é versionada e imutável. Proposta referencia a versão exata usada.

## 7. Bank Table & Pricing Import Engine

Entradas: PDF, manual, planilha padrão Corban ou XLSX/CSV externo. IA pode interpretar layout desconhecido e sugerir mapping; humano confirma; template determinístico versionado executa os próximos arquivos reconhecidos.

Mudança de fingerprint bloqueia importação automática até revisão. Toda importação crítica possui dry-run. IA nunca publica silenciosamente tabela ou verdade financeira.

## 8. Simulação e Proposal Engine

Fluxo inicial:
Customer/Opportunity → Simulation → escolha de Bank/Provider/Agreement/Product/Modality/Table/Term/Rate → Proposal → Documents → Internal Digitization → Operational Pipeline.

A proposta preserva versão da tabela, valores, prazo, taxa, comissão esperada, origem/campanha, cadeia comercial e snapshots necessários.

Também é permitido criar proposta sem simulação e registrar pré-vínculo de proposta externa.

## 9. Document Vault

Customer possui cofre documental geral; Proposal possui checklist e associação lógica aos documentos. O arquivo físico pode ser reutilizado sem upload duplicado, mas cada proposta registra a versão/evidência utilizada.

Checklist é configurável por Bank + Provider + Agreement + Product + Modality. Documento obrigatório ausente bloqueia envio à digitação salvo exceção autorizada e auditada.

## 10. Operacional / Esteira

Sales CRM e Operational Pipeline são separados.

Pipeline operacional é configurável, com estados técnicos padronizados, etapas visuais configuráveis, responsáveis, SLA, campos/documentos obrigatórios, automações, permissões e condições de transição.

Status externo bruto é preservado e normalizado antes de alterar estado canônico.

## 11. Production & Status Sync Engine

Fontes: API bancária, API de Master, webhook, relatório autorizado, XLSX/CSV e upload manual.

Pipeline: Source → Connector/Ingestion → Validation → Normalization → Matching → Domain Event → Operational/Production/Finance.

Workers usam checkpoint/cursor, retry, rate limit, idempotência e DLQ. Webhook é preferido quando disponível.

Sync operacional termina em estado terminal (pago ao cliente ou encerrado/cancelado). O ciclo financeiro pode continuar por anos.

## 12. Production Import e Matching

Importações nunca escrevem cegamente. Arquivo original, hash, origem e lote são preservados.

Matching forte pode usar Bank+Proposal+CPF ou Bank+Contract+CPF. Correspondência provável gera sugestão humana. CPF conflitante bloqueia auto-match.

Valores informado, externo e confirmado/effective são preservados separadamente; divergência não apaga evidência.

## 13. Commission Engine

Comissão suporta componentes múltiplos, percentual, fixo, bônus e override autorizado. Regras e versões são auditáveis.

Preservar: regra padrão → valor esperado → override/effective → banco reportado → recebido → divergência.

Comissão paga é imutável; correções usam adjustment/reversal.

## 14. Deferred Commission

Separar potencial projetado, competência reportada e valor efetivamente recebido. Receita futura não é reconhecida como recebida antecipadamente.

Conciliação diferida ocorre por contrato + tipo de comissão + competência/parcela.

## 15. Reconciliation

Cada Bank/Provider pode possuir perfis versionados de conciliação. Suportar 1:1, 1:N, N:1 e N:N, tolerâncias, duplicidades, unmatched, divergências e Human Gates.

A conciliação é orientada a exceções; lotes sem conflito podem ser processados deterministicamente.

## 16. Commercial Distribution / Repasse

Separar comissão recebida pelo Corban da distribuição para vendedor, supervisor, gerente, corretor, parceiro ou equipe.

Bases possíveis: produção, comissão bruta/elegível/líquida, componente específico, fixo, progressivo ou combinação. Clawback cria reversão/ajuste; nunca apaga pagamento histórico.

## 17. Goals & Incentives

Metas podem ser individuais, equipe, unidade, região, organização ou parceiro. Métricas incluem produção, contratos pagos, receita/comissão recebida, conversão, recuperação e combinações de produto/banco.

Bônus de meta é componente separado da comissão comercial. Atingir 100% não significa pagamento imediato: período fecha, contratos elegíveis são validados e o bônus segue aprovação/pagamento.

## 18. Finance / Financial Pro

Distinguir volume de produção de receita da empresa.

Domínios: expected/confirmed/received commission, deferred, receivables, payables, distributions, bonuses, expenses, cost centers, cash/bank, managerial P&L, cash flow, reconciliation, clawback e append-only ledger.

Tax Engine inicial é gerencial/provisório, não parecer fiscal definitivo.

## 19. Calendar, Tasks e Campaigns

Atividades: ligação, callback, reunião, atendimento presencial, documentos, assinatura, pós-venda e outras. Appointment e Task são conceitos distintos.

Campanhas podem vir de mídia externa, planilha ou audiência interna. Preservar campaign, batch, origin, owner, cost e resultado.

## 20. Communication / Deskcomm

Omnichannel inclui WhatsApp, SMS, e-mail e telefonia por interfaces próprias. Comunicação não cria uma segunda fonte de verdade de Customer.

Deskcomm pode ser produto independente e/ou fornecer capacidades abstraídas ao Corban OS. Adotar seletivamente: BUILD / ADOPT / ABSTRACT.

## 21. SmartMatch

SmartMatch é Revenue Engine opcional para aquisição recebida, atendimento, qualificação, follow-up, recuperação e conversão. Integra por contrato; não assume domínio financeiro/operacional do Corban.

## 22. Connector Marketplace

Separar Connector Definition, Connector Version/Capability, OrganizationConnector, IntegrationConnection, CredentialReference, Entitlement e Usage.

Modelo padrão BYOK/BYOC: serviços externos específicos do tenant são contratados/pagos pelo próprio cliente. Segredos ficam em storage apropriado, nunca frontend/Git/logs/tabelas de negócio.

## 23. Intelligent Import & Migration Hub

Princípio: **IA entende o desconhecido; template executa o conhecido; motor determinístico valida dinheiro; humano decide ambiguidade.**

Migrações legadas passam por raw immutable → staging → parse → normalize → validate → dedup/identity → mapping → dry-run → divergence → approval → chunked import → reconciliation, mantendo lineage completo.

## 24. IA e Multiagentes

IA pode priorizar, resumir, classificar, sugerir mapping, detectar anomalias e executar ações de baixo risco autorizadas. Toda ferramenta é limitada por Organization + User + Entitlement + Capability + Risk.

IA não altera silenciosamente estado financeiro, permissão, tenant, tabela publicada, reconciliação ambígua ou evidência histórica.

## 25. Automation Engine e Human Gates

Automações são event-driven quando possível. Estados mínimos: QUEUED → RUNNING → SUCCEEDED / RETRY_PENDING / HUMAN_REQUIRED / BLOCKED / FAILED / CANCELLED.

Human Gate obrigatório para ambiguidades financeiras, operações destrutivas, mudanças críticas de segurança/credenciais e outras ações de alto risco.

## 26. White Label

Por organização/brand: nome, logo, favicon, cores, login, domínio, identidade de e-mail, documentos e portais, conforme entitlement. White label nunca altera a fronteira de tenant.

## 27. Reporting & BI

Dashboards por papel: Executivo, Comercial, Gestor, Operacional, Financeiro, Campanhas, Importações/Integrações e Meu Dia.

Relatórios devem permitir drill-down até a fonte. AI insights precisam ser derivados de dados rastreáveis.

## 28. Segurança, LGPD e auditoria

- multi-tenant fail-closed;
- backend soberano em autorização;
- RLS como defesa adicional, não substituto de autorização;
- least privilege;
- secrets isolados;
- arquivos externos tratados como não confiáveis;
- audit trail para ações críticas;
- minimização, retenção, anonimização e direitos LGPD;
- backup/restore testado;
- proteção contra IDOR, mass assignment, replay e escalada de privilégio;
- service role restrita a caminhos privilegiados controlados.

## 29. Invariantes centrais

1. Nenhum dado de negócio cruza tenant.
2. Dinheiro não usa Float.
3. Histórico financeiro crítico é append-only/imutável.
4. Eventos externos são idempotentes.
5. Estado técnico e etapa visual não são a mesma coisa.
6. IA não inventa status bancário.
7. Regra/tabela publicada é versionada.
8. Proposal/Contract preserva snapshots históricos.
9. Arquivo externo original e hash são preservados.
10. Deferred potential ≠ received revenue.
11. Goal bonus ≠ commercial commission.
12. Brand ≠ Tenant.
13. Connector externo não vira fonte de verdade do core.
14. Jobs assíncronos não confiam em organization_id recebido no payload sem contexto autorizado.
15. Toda divergência financeira relevante permanece rastreável.

## 30. State Machines mínimas

Opportunity: OPEN → QUALIFYING → QUALIFIED → PROPOSAL_IN_PROGRESS → WON / LOST / CANCELLED.

Proposal: DRAFT → READY → SUBMITTED → UNDER_REVIEW → APPROVED / REJECTED / CANCELLED / EXPIRED, com SUPERSEDED quando aplicável.

Contract: PENDING_FORMALIZATION → FORMALIZING → SIGNED → PENDING_ACTIVATION → ACTIVE, com CANCELLED / TERMINATED / REVERSED.

Finance: External/Contract Event → Expected Receivable → External Confirmation → Reconciliation → Available Value → Commission Calculation → Payable → Payment Instruction → Settlement.

## 31. Primeira entrega vertical

**V0 funcional:** Login/Tenant → Customer 360 → Bank/Product/Table → Simulation → Proposal → Documents → Send to Digitization → Operational Desk → Pipeline.

A V0 deve ser demonstrável ponta a ponta com autorização e isolamento reais. Sync, commissions, reconciliation, deferred, goals e BI entram progressivamente sobre contratos de domínio já preparados.

## 32. Estratégia de execução

Construir fatias verticais testáveis. Não desenvolver dezenas de módulos em paralelo. Reutilizar OSS/SDKs maduros quando reduzirem risco/tempo, sempre atrás de abstrações próprias quando estratégicos.

Aceleração nunca permite pular tenant isolation, migrations, authorization, auditabilidade financeira ou testes de vazamento.

## 33. Definition of Done de produção

Uma capacidade crítica só está pronta quando inclui: modelo/migration versionada, autorização, RLS quando aplicável, validação de entrada, invariantes, idempotência quando aplicável, auditoria, testes unitários/integrados/E2E relevantes, observabilidade, tratamento de erro, documentação e rollback/recuperação.

Antes de produção: tenant-leakage tests, IDOR/mass-assignment, auth revocation, webhook replay/signature, retry/DLQ, financial duplicate/allocation tests, backup restore, migration dry-run, dependency/secret/SAST scans e runbooks.

## 34. Regra documental

Este MASTER descreve **como deve ser**. `CORBAN-CURRENT-STATE.md` descreve **o que existe**. `.ai/CURRENT-TASK.md` descreve **o próximo trabalho**. Divergências devem ser explicitadas, nunca mascaradas.

Arquivos v1.x permanecem como histórico até migração documental concluída.
