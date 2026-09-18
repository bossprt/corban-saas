# CUSTOMER 360 V0 — DATA CONTRACT

**Status:** schema preparado no Git; não aplicado enquanto o gate A/B de tenant estiver pendente.

## Escopo do primeiro incremento

O registro canônico continua sendo `public.clients` para evitar duplicação/migração prematura. A V2 o evolui semanticamente para Customer e adiciona estruturas próprias para endereço, conta bancária, PIX e timeline.

Customer atual:
- identidade: full_name, preferred_name, CPF, nascimento;
- contatos: phone, secondary_phone, email;
- aquisição: source;
- notas operacionais;
- soft delete;
- timestamps.

Coleções:
- `customer_addresses`
- `customer_bank_accounts`
- `customer_pix_keys`
- `customer_timeline_events`

## Invariantes

1. Toda linha carrega `organization_id`.
2. Membership ativo é necessário para leitura/escrita autenticada.
3. Nenhuma tabela nova possui DELETE para authenticated.
4. Timeline é append-oriented: SELECT + INSERT; UPDATE/DELETE não são concedidos por policy.
5. Dados bancários atuais pertencem ao Customer; Proposal/Contract futuros guardarão snapshots próprios.
6. PIX pode apontar para conta bancária, mas a associação é opcional.
7. CPF continua tenant-scoped. A conversão do UNIQUE legado para índice parcial do ADR-0005 será migration separada, após inspeção/gate.
8. Não criar Opportunity neste incremento; Customer 360 deve estabilizar antes da próxima camada comercial.

## Proteção tenant-safe

A revisão adversarial eliminou a FK simples: as tabelas filhas usam FKs compostas `(organization_id, customer_id) → clients(organization_id, id)`. Contas bancárias também recebem identidade composta por tenant e PIX referencia `(organization_id, bank_account_id)`. Assim, referência cruzada entre tenants é bloqueada no próprio banco, independentemente da aplicação.

## Próximo passo

Revisão adversarial do schema para eliminar referências cruzadas de tenant; depois aplicar somente quando o gate de isolamento permitir.