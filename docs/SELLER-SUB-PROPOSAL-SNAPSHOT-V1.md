# Seller/SUB → Proposal Snapshot V1

**Status:** preparado; NÃO LIVE.  
**Objetivo:** transformar a regra SUB cadastrada no vendedor em verdade econômica congelada da proposta.

## Invariante de negócio

A regra de rede e a regra SUB são dimensões diferentes:

```text
comissão bruta do componente
× participação da empresa na rota/rede
= direito econômico antes do vendedor

direito econômico antes do vendedor
× company_share_pct congelado do vendedor SUB
= receita esperada da empresa
```

Exemplos:
- vendedor não-SUB: company share = 100%;
- SUB 100%: company share = 0%;
- SUB 90%: company share = 10%.

Não usar Grupo de Comissão para substituir a regra SUB. O Grupo de Comissão continua sendo a política de remuneração/distribuição; SUB é participação econômica própria do vendedor/rede.

## Mudanças preparadas

- `proposals_v2.seller_id` com FK tenant-safe;
- RPC governada `assign_proposal_seller`, somente em proposta draft e antes de congelar rota;
- snapshots de componente ganham:
  - seller_id;
  - seller_sub_rule_version_id;
  - seller_sub_share_pct;
  - seller_company_share_pct;
- `freeze_proposal_commercial_route` congela o vendedor e resolve regra SUB por componente, com fallback `all`;
- SUB sem regra publicada falha fechado;
- `publish_expected_commission` passa a calcular a receita esperada da empresa usando o company share congelado;
- propostas/snapshots antigos recebem 100% de company share por default e preservam o comportamento econômico anterior.

## Segurança

- seller não pode ser alterado depois do freeze;
- alteração de seller exige RPC dedicada;
- same-tenant FKs em proposta e snapshot;
- regra SUB congelada referencia o mesmo seller;
- nenhuma regra atual é consultada durante publicação financeira: usa somente snapshot congelado;
- nenhum evento financeiro histórico é reescrito.

## Gate

A migration `20261014_seller_sub_proposal_snapshot_v1.sql` precisa passar rollback-only e depois exige autorização explícita antes de LIVE.
