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

## Human Gate atual — DDL
A migration comercial preparada cria novas tabelas/RLS no Supabase de produção. Pela regra do projeto, requer autorização explícita antes de aplicar.

## Próximo passo após autorização
1. Aplicar `20260918_commercial_network_channels_v0.sql`.
2. Executar contract e advisors.
3. Fazer revisão adversarial live e corrigir dentro do escopo autorizado.
4. Construir UI de Rede/Canais/Regras sem inventar dados.
5. Criar import staging para Daycoval/Efetiva/Bevicred preservando arquivo/hash/lineage.
6. Só publicar regras comerciais reais após mapping determinístico e validação.
