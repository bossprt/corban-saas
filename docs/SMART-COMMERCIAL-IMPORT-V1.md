# Smart Commercial Import V1

**Status:** LIVE na fundação de banco e integrado ao fluxo de aplicação. CSV/XLSX/XLS legado/PDF textual suportados; PDF escaneado permanece fora do escopo.

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

## Formatos suportados (XLS + PDF) - 20/09/2026

Um unico ponto de entrada (`src/lib/imports/smart-file.ts`) transforma qualquer upload em `string[][]`; depois segue o mesmo `mapSmartCommercialRows`. Nao existe segundo motor comercial.

| Formato | Leitor | Observacoes |
|---|---|---|
| CSV/TXT | `parseDelimited` | limite 2 MB |
| XLSX | ExcelJS (existente) | antes de abrir: inspecao do zip (bomba, senha, path traversal); lê ate 5.002 linhas e RECUSA se passar do teto (antes cortava em 1.000 em silencio) |
| XLS legado (BIFF) | `@e965/xlsx` 0.20.3 | 1a aba; formulas/HTML/estilos/VBA desligados; datas viram ISO; `%` no formato da celula e RECUSADO (0,15 vs 15 nao se adivinha); erro `#REF!` vira vazio |
| PDF com texto | `unpdf` 1.8.1 (pdf.js sem worker/canvas) | so geometria deterministica: cabecalho reconhecivel + colunas alinhadas; ate 5 MB, 30 paginas, 60 mil itens |

O formato e decidido pelos PRIMEIROS BYTES, nao pelo nome nem pelo MIME: um `.xls` que na verdade e XLSX (comum nos relatorios 2Tech) funciona; `.csv` com binario, `.exe`, HTML disfarcado de Excel e nomes com `../` sao recusados. O nome exibido passa por `safeFileName`; nunca e usado como caminho.

### Bibliotecas escolhidas
- `@e965/xlsx`: fork mantido do SheetJS, Apache-2.0, licenca e API iguais. O pacote npm `xlsx` esta parado em 0.18.5 com CVEs publicados (prototype pollution, ReDoS); por isso NAO foi usado.
- `unpdf`: MIT, wrapper serverless do pdf.js (Mozilla). Alternativas descartadas: `pdf-parse` (pdf.js antigo, sem manutencao), `pdfjs-dist` direto (35 MB, exige worker/canvas config).
- Instaladas com `npm install`; `package-lock.json` gerado pelo npm.

### PDF: regra de recusa
Cabecalho com >= 4 nomes conhecidos; cada linha de dados precisa alinhar suas celulas a colunas, uma celula por coluna. Recusa com `pdf_ambiguous_layout` / `pdf_no_table` / `pdf_no_text` (imagem/escaneado: NAO ha OCR) / `pdf_unreadable`, mensagem "Necessita revisao/mapeamento" e nada e importado. Texto solto so e aceito se estiver DESTACADO da tabela (rodape); colado a ela (ultima linha com celula transbordando, celula quebrada) e recusado. O PDF nunca infere prazo, taxa, fator, comissao, unidade % / R$ nem Tipo de Contrato.

### Regras reforcadas neste ciclo
- Fator DIARIO exige data (`factor_date_required`); data invalida de calendario (32/13/2026, 30/02) e recusada; fator FIXO nao exige data; cada linha carrega a sua data (historico nunca sobrescrito).
- `Fator 0` (HOPE exporta DIARIO com fator 0) = "sem fator": nao e erro nem fator; a taxa sustenta a linha. Fim de vigencia "Nao definida" = sem fim.
- Coluna de dinheiro nao reconhecida (comissao/bonus/repasse/diferido/seguro...) RECUSA o arquivo (`unrecognized_commission_column`); colunas inofensivas conhecidas (Id, Idade, Base Calculo, Valor Contrato...) sao ignoradas.
- Repasse 1/2/3: os "slots" sao listados; nenhum e mapeado a Corretor/Parceiro; `source_repasses` fica vazio e o app exige confirmar "ignorar repasses do arquivo". Nomes reais (`A Vista (Corretor)`) continuam reconhecidos.
- Limites: 2 MB planilha / 5 MB PDF, 5.000 linhas de origem, 20.000 condicoes expandidas, 200 colunas, 200 caracteres de texto.
- Celulas sao DADO: formulas usam o resultado em cache (nunca reavaliam), `=HYPERLINK(...)`, "ignore as instrucoes" etc. viram texto puro. Nenhuma IA le o arquivo nesta camada.
- Bug corrigido: linhas do ExcelJS sao esparsas; `.map` deixava celulas `undefined` e derrubava planilhas com cabecalho vazio (o Daycoval real).

### Limitacoes conhecidas
- XLSX (ExcelJS) nao informa o formato numerico da celula: `15%` guardado como 0,15 nao e detectado (so no XLS). Mitigacao futura: ler `numFmt` no XLSX.
- HTML exportado como `.xls` e recusado (pedir para salvar como XLSX).
- PDF com texto mas sem cabecalho reconhecivel ou com celulas quebradas em varias linhas: recusado (revisao humana). PDF escaneado: sem OCR (futuro, com Human Gate de custo).
- Nao havia PDF/XLS de tabela comercial real na maquina (so relatorios de contratos com dados pessoais, que NAO foram copiados nem commitados): BIFF e PDF foram testados com arquivos sinteticos gerados nos testes + leitura de BIFF real so para confirmar que a biblioteca abre.
- `unknown_contract_type`: Tipos de Contrato do arquivo (ex.: "Refin-Portabilidade", "Contrato Novo") precisam existir/estar habilitados no tenant.

### Testes
`tests/unit/smart-import-formats.test.ts` (21 casos): mesmo resultado em CSV/XLSX/XLS/PDF; conteudo decide o leitor; PDF valido, multipagina, ambiguo (4 formas), sem texto, sem tabela, corrompido, gigante; Refin/Portabilidade e faixa; fator DIARIO/FIXO/0; Diferido 0 e >0; Plastico sem unidade / em R$; % ; Repasse 1/2/3; Corretor/Parceiro; coluna de dinheiro desconhecida; formulas/injecao; zip bomb/senha/traversal; limites; XLS datas/percentual/precisao; wiring do servidor.

### Human Gate
Nenhum novo. Sem DDL, secret, gasto ou servico pago. OCR/IA para PDF escaneado, se desejado, exigira gate de custo/secret.
