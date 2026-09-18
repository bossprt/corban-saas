# SIMULATION / PROPOSAL V0 — DATA CONTRACT

**Status:** preparado no Git; não aplicado.

## Fluxo
Customer → Simulation → ProductTableVersion → Proposal V2.

Proposal pode nascer de Simulation ou diretamente. Em ambos os casos precisa guardar a versão exata da tabela usada.

## Evidência histórica
Proposal guarda snapshots separados:
- `customer_snapshot`: identidade/dados relevantes usados na operação;
- `commercial_snapshot`: Bank/Provider/Agreement/Product/Modality/Table/Version e condições;
- `attribution_snapshot`: origem/campanha/cadeia comercial disponível no momento.

Alterar Customer ou catálogo depois não reescreve a proposta histórica.

## Dinheiro e precisão
Valores monetários usam NUMERIC(14,2), taxa NUMERIC(12,8) e coeficiente NUMERIC(18,10). Não há Float.

## Tenant
Customer, Simulation e ProductTableVersion são referenciados com FKs compostas por `organization_id`. A aplicação não consegue formar proposta cruzando entidades de organizações diferentes apenas manipulando IDs.

## Legado
A tabela atual `contracts` não é reutilizada como Proposal. `proposals_v2` nasce separada para impedir que o modelo legado seja esticado e misture proposta, contrato e produção.

## Estados iniciais
Simulation: draft → calculated → selected; também expired/cancelled.
Proposal: draft → documents_pending → ready_for_digitization → digitization → submitted → approved → paid; cancelled como terminal operacional.

A máquina completa de transição será guardada por serviço/domínio e DB antes de produção. O schema V0 não pretende permitir saltos arbitrários como regra de negócio final.

## Segurança
RLS por membership ativo, sem DELETE autenticado. Índice parcial impede duplicidade de external_proposal_id dentro do tenant quando informado.


## Integridade adicional
Quando Proposal referencia Simulation, Customer e ProductTableVersion precisam coincidir com a simulação selecionada. Proposal exige ProductTableVersion publicada. Depois que a Proposal sai de draft, identidade, valores, snapshots comercial/customer/atribuição e referência de tabela não podem ser reescritos; correções posteriores devem ser modeladas explicitamente.
