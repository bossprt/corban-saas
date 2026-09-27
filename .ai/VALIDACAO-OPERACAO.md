# Validação na operação real (Smart Promotora)

Objetivo: a Smart roda o dia a dia no Corban. Cada passo abaixo é feito com dados reais em produção. O que travar,
confundir ou der número errado vira correção (PR + prova na tela). A venda do Corban (F11) só começa depois disto.

Estado em 27/09/2026 (produção): 1 usuário ativo, 77 vendedores, 99 tabelas, 6 grupos de comissão, 7 bancos,
2 propostas, 0 comissões recebidas, 0 contas bancárias, 0 tipos de documento.

## Preparação (uma vez)

1. Equipe: Equipe > convidar operacional, financeiro e supervisores com o papel certo.
2. Portal: Cadastros > Vendedores > "Dar acesso ao portal" para os corretores que vão usar.
3. Documentos: Documentos > tipos de documento e checklist por banco/produto (RG, contracheque, extrato...).
4. Financeiro > Contas bancárias: C6, BB, Inter, PagSeguro com saldo inicial e data.
5. Financeiro > Plano de contas: conferir e ajustar o padrão.

## Fluxo diário (repetir com contratos reais)

| # | Passo | Tela | Está certo quando |
|---|---|---|---|
| 1 | Cadastrar cliente (ou achar pelo CPF/telefone) | Clientes | não duplica; origem registrada |
| 2 | Simular e criar proposta | Simulações / Propostas > Nova | tabela e comissão prevista batem com a tabela do banco |
| 3 | Corretor envia pelo portal (quando for o caso) | Portal > Nova | cai em Propostas > Aguardando validação |
| 4 | Operacional digita para o corretor | Propostas > Nova | vendedor certo; digitação registrada |
| 5 | Acompanhar a esteira | Operação / Esteira | etapas certas; pendências aparecem na Hoje |
| 6 | Contrato pago ao cliente | Proposta | data de pagamento; físico só se registrado |
| 7 | Importar relatório de comissão do banco | Financeiro > Importar | cada linha acha o contrato; divergência aparece |
| 8 | Conciliar | Financeiro > Conciliação | valor recebido = previsto, ou divergência aceita pelo financeiro |
| 9 | Comissão do vendedor liberada | Repasse | só libera com pago + comissão conciliada (+ físico recebido) |
| 10 | Pagar repasse | Repasse > extrato | valor = soma das comissões liberadas; comprovante |
| 11 | Lançamentos no financeiro | Financeiro > Comissões e repasses a lançar / Contas | entrada da comissão e saída do repasse lançadas |
| 12 | Importar extrato OFX e conciliar | Financeiro > Extrato | cada linha do banco casa com um lançamento |
| 13 | Fechar o mês | Financeiro > Fluxo de caixa e DRE | resultado bate com o que a Smart sabe do mês |

## Como reportar

Para cada problema: tela, o que fez, o que esperava, o que aconteceu (print ajuda). Nunca mandar CPF ou dado de
cliente pelo chat; dizer o número da proposta/ADE.

## Registro

| Data | Passo | Resultado | Correção |
|---|---|---|---|
