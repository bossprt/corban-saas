# Wave B/C — Vendedor, SUB e Fatores

**Status:** preparado, não LIVE.  
**Data:** 2026-09-20.

## Resultado da tripla revisão

### 1. Completude
O cadastro real exige dois vínculos diferentes:
- Grupo de Vendedor;
- Grupo de Comissão.

A categoria comercial do vendedor é PF/PJ/SUB. SUB possui regra econômica; por isso o percentual não fica como campo mutável simples no cadastro.

### 2. Adversarial
Foi rejeitado:
- reutilizar `commission_groups` como Grupo de Vendedor;
- gravar SUB 90/100 como percentual mutável sem versão;
- criar outro motor de split concorrente para contratos históricos;
- colocar fator diário dentro de `commercial_conditions` e obrigar nova versão de Produto/Tabela todos os dias.

A solução preserva as estruturas existentes e adiciona somente as lacunas.

### 3. Validação
Schema LIVE foi inspecionado antes do desenho. Já existem:
- `commission_groups`;
- `commercial_entities/relationships/channels`;
- `network_split_rule_versions`;
- `commission_rule_components` com percentual e valor fixo;
- `commercial_conditions`.

## Migration 20261007 — vendedores
Adiciona:
- `seller_groups`: agrupamento comercial livre do tenant (ex.: BÁSICO, Equipe Acre, Parceiros Premium);
- `commercial_sellers`: vendedor com Grupo de Vendedor + Grupo de Comissão separados e categoria PF/PJ/SUB;
- `seller_sub_rule_versions`: regra econômica de SUB versionada, com `sub_share_pct` e `company_share_pct = 100 - sub_share_pct`;
- resolver temporal e publicação governada;
- RLS; CPF/CNPJ fica supervisor+.

Exemplo:
`SUB 90% -> company_share_pct 10%`.

A proposta futura deve congelar o ID da regra SUB usada no snapshot; nunca recalcular contrato histórico usando regra atual.

## Migration 20261008 — fatores
Adiciona:
- perfil de fator por instituição/convênio/tabela/tipo de contrato;
- modo `daily` ou `fixed`;
- lotes versionados por data e revisão;
- faixas de prazo + valor do fator;
- vínculo opcional ao `import_batches` existente para linhagem de PDF/XLSX/CSV;
- publicação governada;
- resolver determinístico para CRM/simulação.

Resolução:
- perfil mais específico vence;
- diário exige data exata;
- fixo pega a última vigência anterior/igual à data;
- diário vence fixo em empate;
- intervalos de prazo sobrepostos são recusados na publicação.

## Não incluído ainda
- UI final de Vendedores;
- upload/parsing PDF/XLSX de fatores;
- componentes de comissão estendidos (plástico/seguro/bônus 2/3);
- snapshot de vendedor/SUB na proposta;
- automação de importação inteligente.

Esses itens vêm após o schema base estar LIVE e validado.
