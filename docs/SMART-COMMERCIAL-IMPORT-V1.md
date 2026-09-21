# Smart Commercial Import V1

**Status:** preparado, não LIVE.

## Objetivo
Receber uma planilha já validada no aplicativo e, em uma única transação:
- localizar ou cadastrar Instituição;
- localizar ou cadastrar Convênio;
- localizar/criar rota comercial;
- localizar/criar Produto/Tabela;
- usar/criar versão rascunho;
- criar/atualizar condições por Tipo de Contrato + prazo;
- gravar componentes recebidos (À Vista, Diferido, Bônus, Plástico, Seguro etc.);
- vincular a versão da regra interna de comissão;
- importar fator diário/fixo quando vier no arquivo.

## O que NÃO faz
- não publica Produto/Tabela automaticamente;
- não inventa Tipo de Contrato;
- não inventa comissão, unidade ou fator;
- não escolhe regra interna de comissão;
- não cria empresa terceira sem seleção explícita;
- não usa IA para cálculo financeiro.

## Atomicidade
A função `import_smart_commercial_rows` é uma única transação PostgreSQL. Qualquer erro aborta a carga inteira.

## Política
A condição recebe um vínculo imutável/auditável com a versão da política component-aware escolhida no momento da importação.

## Fatores
Quando a planilha traz fator, o importador cria uma nova revisão e publica o lote de fator depois que todas as linhas do lote foram gravadas. Tabela comercial continua em rascunho para revisão humana.

## Próximo passo de aplicação
- parser XLSX/CSV com aliases HOPE/2Tech;
- prévia e perguntas condicionais;
- chamada da RPC somente após confirmação;
- XLS legado/PDF requer parser adicional local.
