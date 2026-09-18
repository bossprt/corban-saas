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
