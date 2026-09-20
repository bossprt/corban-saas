# CORBAN OS — REESTRUTURAÇÃO DE PRODUTO E UX V1

**Data:** 2026-09-20  
**Branch:** `architecture/corban-os-master-v2`  
**Fonte:** revisão do sistema real + material/telas da 2Tech + decisões do Owner.

## Norte do produto

O Corban OS deve ser organizado pelo trabalho do correspondente bancário, não pelas tabelas do banco de dados.

Navegação-alvo:
`Visão geral | CRM | Operacional | Financeiro | Cadastros | Relatórios | Configuração`.

A tela principal de cada área é um hub de trabalho. Cadastros extensos ficam em gerenciadores próprios.

## Protocolo obrigatório de execução — 3 revisões

Antes de qualquer alteração relevante:

### Revisão 1 — completude
- resolve o problema inteiro do próximo passo?
- dependências, RBAC, tenant, dados, rollback e Definition of Done estão claros?
- existe impacto em histórico, comissão, integração ou publicação?

### Revisão 2 — adversarial
- tentar refutar a solução;
- procurar caminho mais simples, barato e seguro;
- procurar regressão de tenant/RLS, histórico, idempotência, comissão e UX;
- conferir se estamos copiando a 2Tech sem necessidade em vez de adaptar o princípio.

### Revisão 3 — execução/validação
- conferir código/schema real antes de escrever;
- executar somente trabalho reversível autorizado;
- testar/buildar e confrontar resultado real;
- atualizar CURRENT-STATE, CURRENT-TASK, DECISIONS e CHANGELOG.

Nenhuma DDL LIVE, secret, gasto, publicação financeira ou ação irreversível é coberta por uma autorização genérica.

## Ondas

### Onda A — arquitetura de navegação e UX
Sem DDL:
- hubs CRM, Operacional, Cadastros e Relatórios;
- menu principal reduzido aos domínios do negócio;
- módulos existentes continuam acessíveis pelos hubs.

### Onda B — Rede/Vendedores
- Grupo de Vendedor separado de Grupo de Comissão;
- cadastro do vendedor vincula ambos;
- Categoria PF/PJ/SUB;
- SUB com regra econômica versionada (100/0, 90/10 etc.);
- permissões/regras operacionais modularizadas.

### Onda C — Produtos
- Produto = Tabela;
- gerenciamento de Tipo de Contrato dentro do domínio Produtos;
- fatores diários e fatores fixos com histórico/vigência;
- modelo de comissão por componentes: à vista, diferido, bônus, bônus 2/3, plástico, seguro e extensíveis;
- componentes podem ser % ou R$.

### Onda D — Importação inteligente
Meta central:
`Upload -> reconhecimento -> regras conhecidas -> perguntas condicionais -> prévia -> importação atômica`.

- PDF/XLSX/CSV;
- importar tabelas, prazos, taxas, fatores, vigências e remuneração recebida;
- modelo Excel gerado com nomes reais dos grupos, nunca somente Repasse 1/2/3;
- regra em camadas: organização -> instituição -> convênio -> produto/tabela -> condição;
- IA propõe mapeamento; motor determinístico calcula;
- perguntar sobre Diferido/Plástico/Bônus somente se existirem e exigirem decisão.

### Onda E — sincronização upstream/downstream
- vínculo explícito entre organizações;
- correlação de contratos;
- eventos de esteira sincronizados;
- tabela upstream informa quanto o upstream paga ao downstream;
- regra interna do downstream nunca é sobrescrita.

### Onda F — CRM/SmartMatch/DeskcommCRM
Corban é o guarda-chuva:
`CORBAN -> SmartMatch + DeskcommCRM`.
Integrações por APIs/eventos/identidades, sem compartilhar secrets ou banco de forma insegura.

## Regra de Claude
ChatGPT executa diretamente tudo que as ferramentas conectadas permitem. Claude só recebe trabalho quando houver dependência real do ambiente local/capacidade não disponível aqui. Quando necessário, a tarefa deve ser longa, coerente e autônoma, não microtarefas, e deve instruir Claude a economizar contexto usando ferramentas/plugins já instalados, índices/caches e leitura seletiva.
