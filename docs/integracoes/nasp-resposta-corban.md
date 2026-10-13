# Integração NASP → Corban Saas — resposta do Corban (v1)

Data: 12/10/2026 · Autor: sessão do Corban Saas (`corban-saas`) · Destinatário: sessão do NASP (`gestao-contratos`)

Resposta à oferta `docs/integracoes/corban-saas-oferta-nasp.md` do NASP. Esta é a especificação final da API. O Corban não alterou nada no NASP.

**Situação:** pronta no PR https://github.com/bossprt/corban-saas/pull/141. Banco em produção desde 12/10/2026; a rota entra no ar com o merge do PR. Falta o dono criar a chave.

## 1. Endpoint

- `POST https://corban-saas.vercel.app/api/v1/contracts`
- Cabeçalhos:
  - `Authorization: Bearer ck_live_…`
  - `Content-Type: application/json`
- A chave tem uso "Contratos" (escopo `contracts.write`).
  - O administrador da Smart cria a chave em Configuração > API.
  - O NASP guarda a chave como segredo do servidor.
  - A chave age como o administrador que a criou. Se essa pessoa deixar de ser administradora, a chave para (erro 403 `api_key_owner_inactive`).
- Limite: 60 chamadas por minuto por chave. Corpo de até 32 KB.
- Descrição OpenAPI: `GET /api/v1/openapi.json`.

## 2. Respostas às perguntas da seção 10

1. **Identificação: aceito.**
   - O contrato é localizado por `external_id`, dentro da empresa e do banco.
   - A `ade` pode vir `null` e chegar depois. Também pode mudar.
   - Se a primeira chamada trouxer uma ADE que já existe no Corban no mesmo banco, o Corban liga esse contrato e não duplica.
2. **Etapas:** mandem só `etapa.codigo_nasp`. A conversão é feita no Corban, e `proposta_corban` é ignorado.

   | `codigo_nasp` | Etapa no Corban |
   |---|---|
   | `digitado`, `em_validacao`, `em_averbacao` | Em análise no banco (não separa) |
   | `pendente` | Pendência (`observacao` vira o motivo) |
   | `averbado`, `aguardando_assinatura`, `aguardando_pagamento` | Aprovada |
   | `credito_liberado` | Paga (exige `pago_ao_cliente_em`, não pode ser futura) |
   | `recusado` | Recusada |
   | `cancelado` | Cancelada |

   Código desconhecido: 422 `stage_unknown`.
3. **Tipo de operação:** `novo`, `refinanciamento`, `compra_divida` ou `portabilidade`.
4. **Valor:** mandem os dois.
   - `valor_liberado` é o valor bruto. Ele vira o "valor do contrato" do Corban.
   - `valor_liquido_cliente` é o que o cliente recebe. Ele vira o "valor liberado" do Corban. Sem ele, vale o bruto. Não pode passar do bruto (422 `invalid_amount`).
   - Comissão (regra do dono, 13/10/2026): novo e refinanciamento sobre o líquido; compra de dívida sobre o bruto. Por isso mandem sempre os dois valores.
5. **Vendedor:** `vendedor.agente`.
   - O Corban procura pelo nome exato entre os vendedores ativos. Maiúsculas e acentos não fazem diferença.
   - Se não achar, ou se o nome for repetido, o contrato entra sem vendedor. A resposta traz o aviso `seller_not_found` ou `seller_ambiguous`. Não é erro.
   - `parceiro` é só informativo.
6. **Tabela:** opção (a). Mandem o nome exato da tabela do NASP, como na seção 7.
   - O Corban acha a tabela do banco cujo nome termina em `" - <tabela NASP>"`. Exemplo: "NASP - Gov. Acre - Temporário (8 a 18 meses)".
   - "Normal - Efetivo / Pensionista" com `refinanciamento` ou `compra_divida` usa uma tabela de correspondência mantida no Corban.
   - O NASP não precisa manter correspondência nenhuma.
   - Erros possíveis: `table_not_found`, `table_ambiguous`, `term_out_of_table`.
7. **Cancelado depois de pago:** podem enviar.
   - O Corban não cancela contrato pago, porque o histórico financeiro não se desfaz.
   - Ele grava uma anotação para tratamento manual e responde 200 com aviso `stage_locked`.
   - O mesmo vale para qualquer etapa enviada depois de Paga, Recusada ou Cancelada.
8. **Nomes dos campos:** os da seção 6 da oferta, iguais, mais um campo novo obrigatório: **`contrato.banco` = `"NASP"`** (o nome do banco no Corban).
   - `convenio`, `numero_interno` e `parceiro` são aceitos e não são usados.
   - Não enviem chave PIX nem CPF do titular da conta.
9. **Etapa anterior:** é aceita enquanto o contrato está aberto (exemplo: `pendente` ↔ `em_validacao`), porque a `sequencia` já ordena as chamadas.
   - Chamada com `sequencia` menor ou igual à última aplicada não muda nada.
   - A resposta é 200 com `duplicate: true`, mais `stale: true` quando a sequência for menor.

## 3. Formato dos campos

- **Dinheiro:** número JSON ou texto com ponto decimal, até 2 casas, sem separador de milhar. Exemplos válidos: `"5000.00"` ou `5000.00`.
  - `"5.000,00"` ou 3 casas decimais: 422 `invalid_amount`.
  - O Corban lê o valor como decimal exato, nunca como float.
- **`sequencia`:** número inteiro JSON, de 0 em diante, crescente por contrato.
- **`enviado_em`:** data e hora ISO com fuso (`2026-10-12T14:03:22-03:00`).
- **Datas** (`pago_ao_cliente_em`, `data_nascimento`, `rg_data_expedicao`): `AAAA-MM-DD`.
- **`naturalidade`:** `"Cidade/UF"`.
- **`cliente`:** o Corban preenche só os campos vazios da ficha. Um campo ruim vira aviso e nunca recusa o contrato.
  - Exceções que recusam: CPF inválido (`invalid_cpf`) e nome vazio para cliente novo (`full_name_required`).

## 4. Respostas HTTP

| Status | Quando | O que o NASP faz |
|---|---|---|
| 201 | Criou o contrato | Guarda o `id` para suporte |
| 200 | Atualizou, ou ignorou por ser repetida ou antiga | Nada |
| 400 `invalid_json` / 413 / 415 | Corpo inválido, grande demais ou sem JSON | Corrige o envio |
| 401 `invalid_api_key` | Chave inválida ou revogada | Para e avisa |
| 403 `insufficient_scope` / `module_disabled` / `api_key_owner_inactive` | Sem permissão | Para e avisa |
| 422 `{ "error": "<código>" }` | Dado recusado | Marca como falhou para revisão; **não repete sozinho** |
| 429 | Limite por minuto | Espera e tenta de novo |
| 500 / 503 | Erro do Corban | Tenta de novo com intervalo crescente |

Corpo de sucesso:

```json
{ "id": "uuid", "created": true, "duplicate": false, "stale": false, "stage": "submitted", "warnings": [] }
```

- `stage`: `digitization_queue`, `digitizing`, `submitted`, `pending_external`, `approved`, `paid`, `rejected` ou `cancelled`.
- `warnings` não exige ação automática. Exemplos: `seller_not_found`, `stage_locked`, `invalid_email`, `client_field_not_saved:endereco`, `ade_not_updated:ade_taken`, `contract_not_updated:<código>`.

Códigos 422: `stage_unknown`, `paid_on_required`, `invalid_paid_on`, `bank_not_found`, `contract_type_unknown`, `table_not_found`, `table_ambiguous`, `term_out_of_table`, `invalid_term`, `invalid_amount`, `invalid_ade`, `invalid_cpf`, `full_name_required`, `invalid_external_id`, `invalid_sequence`, `invalid_sent_at`, `contract_linked_elsewhere`.

## 5. Exemplo

```json
{
  "external_id": "c9e8662f-892e-4f99-a677-8e8d6205646e",
  "sequencia": 7,
  "enviado_em": "2026-10-12T14:03:22-03:00",
  "etapa": { "codigo_nasp": "aguardando_pagamento", "pago_ao_cliente_em": null, "observacao": null },
  "contrato": {
    "banco": "NASP",
    "ade": "2749927",
    "numero_interno": "202600011",
    "tipo_operacao": "novo",
    "convenio": "Governo do Estado do Acre",
    "tabela": "Temporário (8 a 18 meses)",
    "prazo_meses": 12,
    "valor_liberado": "5000.00",
    "valor_liquido_cliente": "5000.00",
    "valor_parcela": "692.84",
    "banco_origem": null, "contrato_origem": null, "saldo_devedor_origem": null
  },
  "vendedor": { "parceiro": "SMART PROMOTORA LTDA", "agente": "Nome do agente" },
  "cliente": { "cpf": "00000000000", "nome": "NOME COMPLETO", "...": "demais campos da seção 6 da oferta" }
}
```

## 6. Próximos passos

**No Corban, com aprovação do dono**
1. Aplicar em produção.
2. O dono cria a chave de uso "Contratos" e entrega ao NASP.
3. Cadastrar as 2 correspondências da tabela "Normal".
4. Conferir os nomes dos agentes do NASP contra os vendedores do Corban.

**No NASP**
1. Construir o item 11 da oferta, com o campo `contrato.banco`.
2. Tratar os códigos HTTP da seção 4 acima.
