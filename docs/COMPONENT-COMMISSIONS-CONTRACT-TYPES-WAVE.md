# Wave D — Componentes de comissão + Tipos de Contrato gerenciáveis

**Status:** preparado, não LIVE.

## Tripla revisão

### Completude
A próxima camada precisa representar o arquivo real visto na operação:
- À Vista;
- Diferido;
- Bônus;
- Bônus 2;
- Bônus 3;
- Plástico;
- Seguro fixo;
- cada componente em % ou R$;
- repasse por Grupo de Comissão;
- imposto/desconto;
- regras que podem mudar por instituição, convênio ou Produto/Tabela.

### Adversarial
Não foi alterado o motor simples já LIVE. A nova camada é aditiva para evitar quebrar condições já cadastradas.
Não serão usados “Repasse 1/2/3” como identidade de negócio.
Não é permitido que IA invente valores: o futuro mapper apenas identifica colunas; cálculo continua determinístico.

### Implementação preparada
`20261009_component_commissions_v1.sql`:
- catálogo de componentes;
- componentes recebidos por condição;
- política component-aware com escopo organização/instituição/convênio/tabela;
- versões imutáveis;
- regra por Grupo de Comissão e componente;
- modos: % do componente recebido, valor direto, ou não repassar;
- desconto/imposto na versão;
- resolver determinístico pela regra mais específica.

`20261010_tenant_contract_types_v1.sql`:
- mantém tipos globais existentes;
- permite Tipo de Contrato próprio do tenant;
- configuração por tenant: habilitado, usar na esteira, usar em comissão;
- Tipo de Contrato continua independente da Tabela e fica no domínio Produtos;
- guard impede usar tipo de outro tenant ou tipo desabilitado em condição.

## Depois do LIVE
- UI Produtos → Tipos de Contrato;
- UI de regras por componentes;
- importador HOPE/2Tech-style com perguntas condicionais;
- modelo XLSX gerado com nomes reais dos Grupos de Comissão;
- preview com “empresa recebe / imposto / grupo recebe / empresa retém” antes da publicação.
