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
