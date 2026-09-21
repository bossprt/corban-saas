# PROSESP — Governo do Acre — plano de carga comercial

Data da análise: 2026-09-21
Arquivo fonte: `WorkBank - Gestão de Créditos (1).xlsx`
SHA-256: `93c65ea8ed70edab18e3020c054758e6e327c2b49efd807b0a57a22ec936cb9e`
Linhas fonte: 203

## Decisões do Owner
- PROSESP será cadastrada como Instituição/Banco da rota.
- Produção: **Própria / Smart**. A Smart é correspondente direto da PROSESP; não existe promotora intermediária nesta rota.
- Convênio: Governo do Acre.
- Mensalidade: ignorar nesta carga.
- Faixas como `300-499` podem ser interpretadas como `300,00-499,99`.
- Grupos padrão:
  - Afiliado: 10% da comissão recebida
  - Balcão: 50% da comissão recebida
  - Call Center: 25% da comissão recebida
  - Smart Promotora: 100% da comissão recebida
- Corretor e Parceiro:
  - quando Smart recebe 8%: pagamento efetivo direto = 3% da operação (equivale a share 37,5% da comissão recebida);
  - quando Smart recebe 5%: pagamento efetivo direto = 2% da operação (equivale a share 40% da comissão recebida);
  - quando Smart recebe 7%: **PENDENTE confirmação do Owner**.
- Sem imposto/desconto informado nesta carga.
- Base da comissão no arquivo: LÍQUIDO.
- A planilha não publica taxa/coeficiente confiável para estas condições; não inventar 0%. São condições de comissão.

## Modelo estrutural
Migration LIVE: `commercial_condition_amount_ranges_v1`, versão Supabase `20260921210534`.
- `commercial_conditions.amount_min`
- `commercial_conditions.amount_max`
- NULL/NULL = qualquer valor, preservando catálogos legados.
- conflito só existe quando **prazo e valor** se sobrepõem para mesma versão + tipo.
- mesma faixa de prazo pode coexistir para valores disjuntos.
- condições de comissão podem existir sem taxa/coeficiente.
- simulação antiga não escolhe silenciosamente condição por valor; se a condição exigir faixa de valor, o caminho legado falha com `contract_value_required`.
- existe overload de simulação com `p_contract_value` explícito.

## Consolidação
As 203 linhas fonte representam sete faixas de valor repetidas. Como a comissão é igual em todas as sete faixas para cada combinação abaixo e a mensalidade foi excluída pelo Owner, o valor pode ser consolidado em **R$ 300,00 a R$ 10.000,00**.

Não preencher lacunas de prazo. Exemplo: 6,7,8,9,10 e 12 não vira 6-12; fica 6-10 e 12-12.

| Perfil | Tipo | Prazo inicial | Prazo final | Valor inicial | Valor final | Comissão recebida | Vigência fonte |
|---|---|---:|---:|---:|---:|---:|---|
| Temporário | Novo | 4 | 5 | 300,00 | 10.000,00 | 5% | 19/08/2025 |
| Temporário | Novo | 6 | 8 | 300,00 | 10.000,00 | 8% | 19/08/2025 |
| Temporário | Refinanciamento | 4 | 5 | 300,00 | 10.000,00 | 5% | 01/08/2025 |
| Temporário | Refinanciamento | 6 | 10 | 300,00 | 10.000,00 | 8% | 01/08/2025 |
| Temporário | Refinanciamento | 12 | 12 | 300,00 | 10.000,00 | 8% | 01/08/2025 |
| Efetivo | Novo | 24 | 24 | 300,00 | 10.000,00 | 7% | 22/08/2025 |
| Efetivo | Novo | 36 | 36 | 300,00 | 10.000,00 | 7% | 22/08/2025 |
| Efetivo | Novo | 48 | 48 | 300,00 | 10.000,00 | 5% | 22/08/2025 |
| Efetivo | Novo | 60 | 60 | 300,00 | 10.000,00 | 5% | 22/08/2025 |
| Efetivo | Refinanciamento | 24 | 24 | 300,00 | 10.000,00 | 7% | 01/08/2025 |
| Efetivo | Refinanciamento | 36 | 36 | 300,00 | 10.000,00 | 7% | 01/08/2025 |
| Efetivo | Refinanciamento | 48 | 48 | 300,00 | 10.000,00 | 5% | 01/08/2025 |
| Efetivo | Refinanciamento | 60 | 60 | 300,00 | 10.000,00 | 5% | 01/08/2025 |
| Comissionado | Novo | 4 | 4 | 300,00 | 10.000,00 | 5% | 19/08/2025 |
| Comissionado | Refinanciamento | 4 | 5 | 300,00 | 10.000,00 | 5% | 01/08/2025 |
| Comissionado | Refinanciamento | 6 | 10 | 300,00 | 10.000,00 | 8% | 01/08/2025 |

Total após consolidação: **16 condições**.

## Gate restante
Não persistir a carga PROSESP até o Owner definir o pagamento de **Corretor e Parceiro nas condições de 7%**.
