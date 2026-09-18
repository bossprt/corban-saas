# BANK / PRODUCT / TABLE V0 — DATA CONTRACT

**Status:** preparado no Git; não aplicado.

## Modelo

Catálogo global:
`Bank → Provider/Master → Agreement → Product → Modality`

No contrato V0, `Agreement` pertence a um `Bank`; a rota não pode combinar convênio de outro banco. `Provider/Master` continua sendo dimensão independente da rota, porque o mesmo convênio bancário pode ser operado por canais/fornecedores diferentes.

Configuração do tenant:
`OrganizationProductRoute`

Tabela comercial:
`ProductTable → ProductTableVersion`

A rota explicita que o mesmo banco/produto pode ser operado via fornecedores/Masters diferentes e com economia diferente por organização.

## Regras

- catálogo global não recebe escrita direta de authenticated;
- tenant escolhe/habilita rotas próprias;
- `modality_id` é validado junto com `product_id`; uma rota não pode combinar modalidade de outro produto;
- privilégios de manutenção de `service_role` são explícitos e não dependem de defaults do owner;
- ProductTable é identidade lógica;
- ProductTableVersion é versão histórica;
- proposta futura deverá referenciar exatamente `product_table_version_id`;
- valores decimais usam NUMERIC, nunca Float;
- nenhuma tabela V0 recebe DELETE de authenticated;
- published não pode ser editada pela policy normal; UPDATE autenticado fica limitado a versão ainda `draft`;
- trigger de defesa em profundidade impede alteração do snapshot comercial depois que a versão deixa `draft`, inclusive por caminhos privilegiados comuns;
- publicação final exigirá serviço de domínio/Human Gate e guarda de imutabilidade no banco antes de produção.

## Segurança tenant

Rotas e tabelas carregam `organization_id`. FKs compostas garantem que ProductTable não aponte para rota de outro tenant e que ProductTableVersion não aponte para tabela de outro tenant.

## Fora deste incremento

CommissionRuleVersion, importação PDF/XLSX, fingerprints, dry-run, publication workflow completo e Proposal. Estes entram em migrations/serviços próprios sem deformar o catálogo mínimo.
