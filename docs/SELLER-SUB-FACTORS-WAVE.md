# Wave B/C — Vendedor, SUB e Fatores

**Status:** schema base LIVE; UI de Vendedores e Fatores LIVE. Integração Vendedor/SUB → proposta/financeiro ainda pendente.  
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

## Estado atual após implementação

LIVE:
- `seller_commercial_profile_v1` sob versão Supabase `20260920235725`;
- `commercial_factors_v1` sob versão Supabase `20260920235731`;
- UI `/app/cadastros/vendedores` com Grupo de Vendedor + Grupo de Comissão + PF/PJ/SUB;
- regra SUB versionada/publicada, inclusive 100/0 e 90/10;
- UI `/app/comercial/fatores` para fator diário/fixo;
- Smart Import consegue ingerir fatores por arquivo.

Ainda não incluído:
- congelar o vendedor e a versão da regra SUB na proposta;
- aplicar `company_share_pct` do SUB ao fato `commission_expected`;
- payout financeiro do vendedor/grupo (continua separado da receita esperada da empresa).

Essa integração deve ser nova migration aditiva, preservar propostas antigas como company share 100%, congelar a regra SUB por componente e nunca recalcular histórico pela regra atual.
