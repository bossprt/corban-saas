# CORBAN OS — MODELO COMERCIAL V3 / HANDOFF MASTER

**Data da decisão:** 2026-09-19  
**Status:** decisão de produto aprovada pelo Owner; implementação ainda deve ser feita com auditoria/migração segura.  
**Branch obrigatória:** `architecture/corban-os-master-v2`  
**Regra:** nunca trabalhar na `main`. Não executar migração destrutiva nem alteração irreversível em produção sem Human Gate explícito.

---

## 1. POR QUE ESTE DOCUMENTO EXISTE

Durante o teste real como **Smart Promotora**, o Owner percebeu que o tenant entrava no sistema e não conseguia montar sua própria operação comercial sem depender do Platform Admin. Isso causou estranheza porque, no mercado de correspondente/master, cada empresa trabalha com bancos, convênios, tabelas, prazos e comissões próprios.

A arquitetura anterior tratava `Product` como produto genérico global (ex.: Empréstimo Consignado) e `Modality` como filha desse produto. Essa interpretação não corresponde ao vocabulário operacional que o Owner usa e deve ser corrigida.

Este documento passa a ser a especificação funcional prioritária para o próximo incremento do catálogo comercial e comissões.

---

## 2. PRINCÍPIO CENTRAL

### Platform Admin
Entrega **estrutura padrão do sistema**, cadastros de referência realmente universais e templates nacionais reutilizáveis.

### Admin da empresa / tenant
Controla **a própria operação comercial** e deve conseguir trabalhar sem depender do Platform Admin para montar bancos, convênios, produtos/tabelas, prazos, coeficientes e comissões.

Regra de UX:
> **Usuário informa dados de negócio; identificadores técnicos ficam escondidos e são gerados automaticamente.**

UUID continua sendo o identificador real. Códigos/slugs técnicos só existem internamente para integrações, importação e deduplicação.

---

## 3. VOCABULÁRIO DE NEGÓCIO APROVADO

A sequência operacional desejada é:

```text
Banco / Instituição
    ↓
Convênio
    ↓
Produto (Tabela comercial)
    ↓
Tipo de Contrato
    ↓
Prazo
    ↓
Coeficiente / taxa quando aplicável
    ↓
Comissão recebida pela empresa
    ↓
Distribuição por Grupos de Comissão
```

Exemplo:

```text
Banco Pan
→ Governo do Acre
→ Tabela Servidor 001
→ Novo
→ 84x
→ coeficiente 0,0...
→ comissão recebida 7,00%
```

Depois a empresa decide como distribuir essa comissão segundo grupos/regras próprias.

---

## 4. O QUE SIGNIFICA CADA ENTIDADE

### Banco / Instituição
Quem origina/concede a operação. A empresa usuária deve cadastrar/habilitar as instituições com que trabalha.

### Convênio
Folha/público/ente pagador/estrutura onde a operação existe, ex. Governo do Acre, Prefeitura de Rio Branco, INSS, SIAPE.  
Convênio **não deve nascer preso a um banco no catálogo nacional**. A empresa posteriormente relaciona o convênio às suas condições comerciais.

### Produto = Tabela comercial
No vocabulário do Owner e dos sistemas usados no setor, o “Produto” operacional é a própria tabela/oferta comercial. Não confundir com categoria genérica como “Empréstimo Consignado”.

Exemplo:
- Tabela Servidor 001
- Tabela Novo 84x
- Tabela Cartão X
- qualquer nome comercial fornecido pelo banco/master.

A arquitetura atual já tem `ProductTable/ProductTableVersion`; o executor deve avaliar se essa estrutura pode se tornar a fonte de verdade do “Produto (Tabela)” sem renome destrutivo.

### Tipo de Contrato
Vocabulário aprovado para o que antes aparecia como “Modalidade”.

Exemplos pré-configurados:
- Novo
- Refinanciamento
- Compra de Dívida
- Portabilidade

**Tipo de Contrato é global/padrão e NÃO deve depender de Produto.**
O tenant deve receber os tipos comuns prontos e pode, se necessário, cadastrar/editar/habilitar outros conforme governança definida.

Internamente o banco atual usa `modalities/modality_id`. Não renomear tabela/FK destrutivamente apenas por UX. Avaliar migração segura ou nova entidade `contract_types`.

### Prazo
Número de parcelas/meses aplicável àquela combinação comercial, ex. 24x, 36x, 48x, 60x, 84x, 96x.

### Comissão recebida
Percentual/valor que a empresa recebe na condição comercial. Deve ser armazenado com NUMERIC/inteiro escalado, **nunca Float**.

### Provedor / Master
Origem/canal pelo qual a empresa acessa a tabela quando aplicável. É separado de Banco/Instituição. Deve ser controlado pelo tenant, porque cada empresa opera com fornecedores diferentes.

---

## 5. RESPONSABILIDADE: PLATFORM x TENANT

### Deve vir do Platform Admin / sistema
1. Tipos de Contrato padrão.
2. Tipos de documento comuns/templates.
3. Catálogo nacional de entes públicos reutilizáveis.
4. Estrutura técnica, regras de segurança e templates.
5. Opcionalmente modelos iniciais de grupos de comissão, **sempre editáveis ou substituíveis pelo tenant**.

### Deve ser controlado pela empresa usuária
1. Bancos/Instituições utilizados.
2. Provedores/Masters.
3. Convênios habilitados e convênios próprios adicionais.
4. Produto/Tabela comercial.
5. Prazo.
6. Coeficiente.
7. Taxa, quando aplicável.
8. Comissão recebida.
9. Vigência.
10. Grupos de comissão.
11. Percentuais/regras de repasse por grupo.
12. Gerente/supervisor e regras hierárquicas.
13. Checklist específico e demais regras da operação.

O tenant deve entrar no sistema e conseguir começar a configurar sua operação sem aguardar cadastro comercial do Platform Admin.

---

## 6. CATÁLOGO NACIONAL PRÉ-PRONTO

Criar uma camada de **templates nacionais**, não ativa automaticamente para todos os tenants.

### Governos
Disponibilizar os 27 entes estaduais:
- 26 Estados;
- Distrito Federal / Governo do Distrito Federal.

### Capitais
Disponibilizar as prefeituras dos 26 municípios capitais.  
**Brasília não é município e não possui prefeitura**; para o DF usar Governo do Distrito Federal.

### Experiência desejada
O Admin da empresa vê a lista e pode:

```text
Governo do Acre                 [Habilitar]
Prefeitura de Rio Branco        [Habilitar]
Governo de Rondônia             [Habilitar]
Prefeitura de Porto Velho       [Habilitar]
...
```

Depois de habilitado:
- pode usar na própria operação;
- pode desabilitar;
- pode editar dados específicos permitidos para sua organização;
- pode cadastrar convênio adicional que não esteja na base.

Não duplicar o mesmo Governo/Prefeitura globalmente para cada banco.

Arquitetura recomendada:
```text
NationalAgreementTemplate (global/read-only)
        ↓ enable/copy/link
OrganizationAgreement (tenant)
        ↓
condições comerciais da organização
```

O executor deve adaptar nomes à arquitetura real encontrada, sem forçar esse nome de tabela.

---

## 7. IDENTIFICADORES / CÓDIGOS

O usuário **não deve digitar nem precisar enxergar códigos técnicos** em:
- Produto/Tabela;
- Tipo de Contrato;
- Convênio;
- Tipo de Documento;
- demais cadastros onde o código não represente informação de negócio real.

Fluxo:
```text
Nome: Compra de Dívida
→ sistema gera identificador técnico internamente
→ conflito resolvido automaticamente
→ usuário não vê o campo
```

Para instituições, o código oficial eventualmente pode existir como dado de negócio (COMPE/ISPB/outro identificador real), mas não deve ser confundido com slug técnico. Se não houver código oficial, não exigir um.

---

## 8. GRUPOS DE COMISSÃO

O sistema deve suportar grupos dinâmicos, configuráveis por tenant.

Exemplos observados/esperados:
- Corretor
- Parceiro
- Indicador
- Funcionário
- Time de vendas
- Balcão
- outros criados pela empresa

Um grupo não é simplesmente “usuário = X%”. O grupo define **a regra de cálculo/distribuição**.

A empresa vincula usuários/equipes aos grupos.

### Gerente e Supervisor
Devem existir como opções configuráveis, não necessariamente obrigatórias:
- comissão de gerente;
- comissão de supervisor;
- base de cálculo configurável conforme política da empresa.

Exemplos de base:
- produção total;
- comissão de repasse;
- spread;
- outra base explicitamente definida.

Não presumir uma única fórmula universal.

---

## 9. CADASTRO ÚNICO DA CONDIÇÃO COMERCIAL

Ao cadastrar uma condição:

```text
Banco
+ Convênio
+ Produto/Tabela
+ Tipo de Contrato
+ Prazo
```

o usuário deve poder informar **na mesma operação**:

- coeficiente;
- taxa, se houver;
- comissão total recebida pela empresa;
- percentuais/regras para todos os grupos de comissão habilitados;
- gerente/supervisor se aplicável;
- vigência.

Não obrigar a cadastrar a mesma tabela várias vezes para grupos diferentes.

Exemplo conceitual:

| Banco | Convênio | Produto/Tabela | Tipo Contrato | Prazo | Comissão Empresa | Corretor | Parceiro | Indicador | Funcionário | Supervisor | Gerente |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Pan | Governo do Acre | Tabela 001 | Novo | 84x | 7,00% | 4,00% | 3,50% | 1,00% | 2,00% | 0,30% | 0,20% |

**A semântica de cada coluna deve ser explícita**: percentual direto sobre produção/comissão base ou percentual da comissão de referência. Não misturar modelos silenciosamente.

---

## 10. IMPORTAÇÃO

A mesma estrutura deve aceitar:
1. cadastro manual;
2. importação CSV/XLSX;
3. integração/API futura.

Todas convergem para o mesmo modelo interno.

Na planilha, cada **Grupo de Comissão** pode aparecer como coluna dinâmica para permitir cadastrar toda a distribuição de uma condição numa linha, evitando repetir o produto/tabela 5x.

O importador deve usar identificadores internos gerados automaticamente e regras de deduplicação; o usuário não precisa inventar códigos.

Preservar dados brutos de origem conforme governança existente.

---

## 11. COMISSÃO DE ENTRADA x REPASSE

Não confundir:

### Comissão recebida
Quanto a empresa recebe da operação.

### Regra de repasse
Quanto a empresa decide distribuir para grupos/pessoas.

Exemplo:
```text
Comissão recebida = 7,00%
Grupo Corretores = regra configurada
Parceiros = regra configurada
Supervisor = opcional
Gerente = opcional
Empresa = saldo conforme regra
```

A política comercial deve poder mudar sem alterar o histórico das tabelas já publicadas. Usar versionamento/snapshot imutável quando necessário.

---

## 12. PROBLEMAS DA MODELAGEM ATUAL QUE DEVEM SER CORRIGIDOS

1. `products` hoje representa produto genérico global; isso conflita com o uso de Produto=Tabela pelo Owner.
2. `modalities` hoje depende de `product_id`; Tipo de Contrato não deve depender de Produto.
3. `agreements` hoje depende de `bank_id`; catálogo nacional de convênios não deve duplicar Governo/Prefeitura por banco.
4. Platform Admin hoje concentra referências que deveriam ser autonomia do tenant.
5. Catálogo do tenant ainda espera referências globais para conseguir montar rota.
6. Comissão precisa se ligar à condição comercial e aos grupos de comissão em cadastro único/importação, sem repetição.
7. UI deve esconder códigos técnicos.
8. Registros históricos publicados não podem ser quebrados por migrações de nomenclatura.

---

## 13. ESTRATÉGIA DE MIGRAÇÃO ESPERADA

**Não executar um renome destrutivo de tabelas/FKs só para refletir vocabulário.**

Antes de codificar:
1. auditar schema, migrations, RLS, RPCs, componentes e testes atuais;
2. mapear todas as dependências de `products`, `modalities`, `agreements`, `organization_product_routes`, `product_tables`, `product_table_versions`, comissões e proposals;
3. decidir a menor migração compatível;
4. preservar histórico;
5. criar backfill apenas se necessário e determinístico;
6. manter tenant fail-closed;
7. manter publicação/versionamento imutável;
8. usar NUMERIC/inteiros escalados para dinheiro/percentuais;
9. migration nova, nunca editar migration já aplicada;
10. testar rollback-only antes de qualquer Human Gate LIVE.

Se uma camada nova for mais segura que reaproveitar conceitos antigos, preferir camada nova + adaptação gradual.

---

## 14. UX-ALVO DO TENANT

Ao entrar como Admin da Smart, o usuário deve encontrar um onboarding claro:

```text
1. Habilitar/cadastrar Bancos
2. Habilitar/cadastrar Convênios
3. Cadastrar Produto/Tabela
4. Selecionar Tipo de Contrato
5. Cadastrar Prazos/coeficientes
6. Informar comissão recebida
7. Distribuir comissão entre grupos
8. Publicar/ativar
```

O sistema deve mostrar progresso/configuração faltante, não uma tela vazia dependente do Platform Admin.

---

## 15. DEFINITION OF DONE DO PRÓXIMO INCREMENTO

O incremento só está concluído quando:

- tenant novo consegue montar sua operação sem intervenção comercial do Platform Admin;
- Tipos de Contrato padrão existem independentemente de Produto;
- catálogo nacional de 27 governos + 26 prefeituras de capitais/GDF está disponível como template habilitável;
- tenant pode cadastrar convênio adicional;
- Produto/Tabela é tenant-owned;
- prazo/coeficiente/comissão podem ser cadastrados na condição comercial;
- grupos de comissão são tenant-owned e dinâmicos;
- uma condição comercial aceita vários grupos em um único cadastro;
- importação tem desenho compatível com colunas por grupo;
- códigos técnicos não aparecem como obrigação de cadastro;
- histórico e RLS não regressam;
- testes unit/typecheck/lint/build verdes;
- testes SQL de tenant isolation/RBAC/publicação/comissão verdes;
- docs e handoff atualizados;
- commits/push apenas na branch `architecture/corban-os-master-v2`;
- nenhuma DDL LIVE sem Human Gate explícito.

---

## 16. O QUE NÃO FAZER

- Não tornar Platform Admin operador comercial de cada tenant.
- Não obrigar o tenant a solicitar cadastro de banco/convênio/tabela ao Platform Admin.
- Não cadastrar “Novo” repetidamente por Produto.
- Não duplicar “Governo do Acre” por banco no catálogo nacional.
- Não exigir código técnico ao usuário.
- Não armazenar comissão em Float.
- Não gravar regra de comissão apenas no usuário; usar grupo/política/versionamento.
- Não apagar/renomear tabelas históricas de forma destrutiva.
- Não quebrar propostas/tabelas publicadas existentes.
- Não executar produção/LIVE sem o gate correspondente.

---

## 17. REFERÊNCIA VISUAL / BENCHMARK FUNCIONAL

O Owner mostrou o fluxo da 2Tech como referência conceitual, não para cópia visual.

Pontos observados:
- grupos de comissão cadastráveis;
- vinculação por produto;
- grupo de vendedor + vendedor + grupo de comissão;
- grupo guarda regras de distribuição;
- suporte a gerente e bases de cálculo;
- planilha com uma coluna por grupo;
- cadastro/importação da condição comercial uma vez e distribuição das comissões na mesma linha.

O Corban OS deve implementar o princípio de negócio com arquitetura própria, multi-tenant, auditável e versionada.

---

## 18. PRÓXIMA EXECUÇÃO

Claude deve assumir como executor local de longa duração, seguindo `AGENTS.md`, `.ai/RULES.md`, `.ai/DECISIONS.md`, `.ai/CLAUDE-LONG-RUN.md` e este documento.

Primeiro passo obrigatório: **auditoria de impacto e plano de migração**, depois implementação reversível na feature branch. Se DDL LIVE for necessária, parar no Human Gate e retornar ao ChatGPT/Owner com a migration preparada, testes e evidências.


## 19. NOVOS REQUISITOS DE UX — CEP E ORIGEM/CORRESPONDENTE

### 19.1 Cadastro de cliente — CEP com preenchimento automático
No cadastro/edição de cliente, ao informar um CEP válido o sistema deve consultar uma fonte de CEP e preencher automaticamente, quando disponíveis:
- logradouro;
- bairro;
- cidade/município;
- UF;
- complemento sugerido apenas se a fonte retornar.

O usuário continua responsável por:
- número;
- complemento específico do imóvel;
- corrigir/confirmar o endereço antes de salvar.

Requisitos:
- aceitar CEP com ou sem máscara;
- normalizar para 8 dígitos;
- não bloquear cadastro se a consulta externa estiver indisponível;
- permitir edição manual após o preenchimento;
- tratar CEP inexistente/ambíguo com feedback claro;
- evitar expor segredo no navegador se a fonte exigir chave;
- preferir fonte sem custo/chave para V0 quando adequada;
- não sobrescrever silenciosamente endereço que o usuário já corrigiu manualmente.

### 19.2 Produto/Tabela — origem comercial / correspondente
Ao cadastrar Produto/Tabela, a empresa precisa informar **por qual origem comercial aquela tabela é operada**.

Benchmark funcional observado pelo Owner na 2Tech:
- EFETIVA+
- HOPE
- LEVE
- NOVA PROMOTORA
- PRÓPRIO

No Corban OS esse conceito deve aproveitar, quando compatível, a dimensão já existente de **Provedor/Master**, preservando a regra arquitetural de que:
- Banco/Instituição ≠ Provedor/Master;
- Provedor/Master representa origem/canal comercial da tabela;
- a opção **Próprio** representa operação direta/própria da organização, sem confundir com banco.

UX desejada:
```text
Origem da tabela / Correspondente
[ Próprio ]
[ Lev ]
[ Efetiva+ ]
[ outro provedor cadastrado pelo tenant ]
```

O tenant deve poder cadastrar/editar seus próprios provedores/origens. Não depender do Platform Admin para isso.

**Pendente de definição pelo Owner:** melhoria final de UX/nomenclatura para esse campo além do benchmark da 2Tech. Não implementar uma taxonomia rígida antes dessa definição.


### 19.3 Produção própria x produção de terceiro

Decisão funcional do Owner:

- Se a organização opera como **Master** ou **Sub**, a produção é considerada **Própria**.
- Só deve ser tratada como produção de **Terceiro** quando a tabela/operação vier de uma empresa externa, como:
  - Lev;
  - Bevi;
  - Efetiva;
  - outra correspondente/promotora/parceiro.

Isso significa que o campo de UX não deve induzir o usuário a classificar toda operação como “Correspondente”.

Modelo recomendado:

```text
Origem da Produção
[ Própria ]
[ Terceiro ]
```

Se selecionar **Própria**:
- não exigir fornecedor externo;
- a organização atual é a responsável comercial pela produção.

Se selecionar **Terceiro**:
- exigir selecionar/cadastrar a empresa de origem;
- essa empresa pode ser classificada como:
  - Correspondente;
  - Promotora;
  - Parceiro;
  - outro tipo futuro, se necessário.

Exemplo:

```text
Origem da Produção: Terceiro
Empresa de Origem: Lev
Tipo: Promotora/Parceiro
```

ou:

```text
Origem da Produção: Própria
```

Observação arquitetural:
- não confundir “Própria” com Banco;
- não confundir “Terceiro” com Provedor técnico;
- o executor deve revisar se a entidade atual `providers` pode representar essa empresa de origem sem perda semântica. Se não puder, criar camada compatível em vez de deformar o conceito existente.


## 20. IMPORTAÇÃO INTELIGENTE DE TABELAS E REPASSE POR GRUPO

### 20.1 Dor de negócio
Bancos, promotoras, correspondentes e parceiros normalmente fornecem suas condições comerciais por **Excel/XLSX** ou **PDF**. O objetivo do Corban OS é eliminar o retrabalho de cadastrar manualmente cada produto/tabela, prazo e comissão.

Fluxo desejado:
1. usuário envia Excel/XLSX ou PDF da origem;
2. sistema lê e normaliza as condições comerciais;
3. sistema identifica, quando possível: banco/instituição, convênio, produto/tabela, tipo de contrato, prazo, coeficiente/taxa, comissão recebida, vigência e origem da produção;
4. mostra uma prévia/dry-run para confirmação;
5. usuário informa ou reutiliza a política de repasse por Grupo de Comissão;
6. sistema calcula automaticamente quanto cada grupo recebe para cada linha;
7. usuário aprova e publica/importa.

Não publicar silenciosamente dados extraídos de PDF/Excel. Sempre existir etapa de revisão/confirmação antes da efetivação.

### 20.2 Política de repasse por grupo
O Owner quer definir o repasse como **percentual da comissão efetivamente recebida pela empresa**, e não repetir um percentual absoluto manualmente em cada produto.

Exemplo de política:
- Corretor = 65% da comissão recebida;
- Parceiro = 80% da comissão recebida;
- Balcão = 50% da comissão recebida;
- Indicador = 25% da comissão recebida.

Se a comissão recebida pela empresa for **10%** e não houver imposto/desconto aplicável à base:
- Corretor recebe 6,50%;
- Parceiro recebe 8,00%;
- Balcão recebe 5,00%;
- Indicador recebe 2,50%.

Fórmula conceitual:
```text
comissao_grupo = comissao_base_liquida × percentual_de_repasse_do_grupo
```

Exemplo:
```text
10,00% × 65% = 6,50%
10,00% × 80% = 8,00%
10,00% × 50% = 5,00%
10,00% × 25% = 2,50%
```

### 20.3 Base bruta x base líquida
O sistema deve separar explicitamente:
- **Comissão recebida bruta**;
- impostos/descontos aplicáveis, se configurados;
- **Comissão base líquida para repasse**;
- percentual de repasse do grupo;
- comissão efetiva do grupo.

Se não houver imposto/desconto:
```text
comissão bruta = comissão base líquida
```

Não assumir que imposto é sempre zero. A empresa deve poder configurar se o repasse usa:
- comissão bruta; ou
- comissão líquida após tributos/descontos.

Essa regra precisa ser versionada e auditável.

### 20.4 Reuso da política
A empresa não deve informar 65%, 80%, 50%, 25% em todas as linhas da planilha.

Deve ser possível salvar uma **Política/Grupo de Repasse** e aplicar em lote:
```text
Política: Smart Padrão 2026
Corretor 65%
Parceiro 80%
Balcão 50%
Indicador 25%
```

Ao importar uma planilha com centenas de condições, o usuário escolhe a política e o sistema calcula todas as comissões derivadas automaticamente.

Também deve ser possível sobrescrever uma condição específica quando necessário, com rastreabilidade.

### 20.5 Importação Excel/XLSX
Prioridade operacional para V1:
- upload XLSX/CSV;
- detecção/mapeamento de colunas;
- prévia antes de gravar;
- identificação de duplicidade/conflitos;
- cálculo automático por grupos;
- importação em lote;
- relatório de linhas aceitas/rejeitadas;
- preservação do arquivo/raw source e lineage conforme governança já existente.

### 20.6 Importação PDF
PDF deve entrar como segunda etapa do mesmo pipeline:
- extrair tabelas/condições;
- atribuir nível de confiança;
- nunca publicar automaticamente linha ambígua;
- exigir revisão quando banco/convênio/produto/prazo/comissão não forem determinísticos.

### 20.7 Regras financeiras
- nunca Float;
- usar NUMERIC/inteiro escalado;
- preservar comissão original da fonte;
- comissão calculada para grupos deve ser derivada/versionada;
- alteração futura na política de repasse não deve reescrever contratos/histórico já fechado;
- propostas/contratos devem manter snapshot da regra aplicada.


## 21. IMPORTAÇÃO ADAPTATIVA POR AGENTE DE IA

### 21.1 Decisão do Owner
As regras de repasse/comissão são **tenant-owned**: cada empresa usuária cria e mantém suas próprias políticas.

Exemplo:
- Corretor = 65% da comissão base;
- Parceiro = 80%;
- Balcão = 50%;
- Indicador = 25%.

Essas regras não são globais da plataforma e não devem ser impostas pelo Platform Admin.

### 21.2 Problema dos layouts fixos
Planilhas de bancos, promotoras e parceiros mudam com frequência:
- novas colunas;
- nomes diferentes;
- ordem alterada;
- abas diferentes;
- campos removidos/adicionados;
- formatos variados de comissão, prazo, coeficiente, vigência e convênio.

Portanto, **não construir o importador principal baseado em um template rígido de Excel por fornecedor** como fonte de verdade operacional.

Templates/mapeamentos salvos podem existir apenas como aceleração/fallback, nunca como dependência estrutural que quebra quando o fornecedor muda o arquivo.

### 21.3 Papel do agente de IA
O pipeline deve possuir um **Agente de Importação Comercial** capaz de:

1. receber XLSX/CSV/PDF;
2. inspecionar estrutura, abas, cabeçalhos, amostras e tipos de dados;
3. inferir semanticamente quais campos representam banco, convênio, produto/tabela, tipo de contrato, prazo, coeficiente, taxa, comissão, vigência e origem;
4. comparar a inferência com o schema canônico do Corban OS;
5. propor mapeamento com nível de confiança e evidência;
6. detectar campos novos/desconhecidos em vez de descartá-los;
7. pedir validação humana apenas nos pontos ambíguos;
8. gerar uma prévia/dry-run;
9. aplicar a política de repasse escolhida pelo tenant;
10. importar somente após confirmação.

### 21.4 Aprendizado sem acoplamento
Quando o usuário confirma um mapeamento:
- o sistema pode salvar a decisão por fornecedor/origem como memória operacional;
- em arquivos futuros semelhantes, reutiliza esse conhecimento;
- se o layout mudar, o agente reavalia em vez de falhar silenciosamente;
- divergências relevantes devem reabrir revisão.

Não treinar/ajustar modelo proprietário do usuário como requisito para V1; usar memória/mapeamentos versionados + inferência do agente.

### 21.5 Guardrails
O agente **não pode**:
- publicar/importar silenciosamente campos financeiros ambíguos;
- inventar comissão, prazo, coeficiente, banco ou convênio;
- descartar coluna desconhecida sem registrar;
- sobrescrever tabela publicada/histórico;
- alterar política de repasse do tenant sem ação explícita;
- usar Float para valores/percentuais financeiros.

Deve:
- preservar arquivo bruto;
- guardar lineage/mapeamento;
- registrar confiança e decisões humanas;
- manter trilha de auditoria;
- permitir rollback/reprocessamento;
- separar extração, interpretação, cálculo e publicação.

### 21.6 Arquitetura-alvo do pipeline

```text
Arquivo recebido (XLSX/CSV/PDF)
        ↓
Leitor estrutural determinístico
        ↓
Agente IA de interpretação semântica
        ↓
Schema canônico proposto
        ↓
Validação / confiança / conflitos
        ↓
Prévia humana
        ↓
Política de repasse do tenant
        ↓
Cálculo das comissões por grupo
        ↓
Importação versionada
        ↓
Publicação
```

O componente determinístico continua responsável por leitura do arquivo, tipos, normalização e validações matemáticas. A IA decide **semântica/mapeamento**, não substitui integridade transacional nem regras financeiras.

### 21.7 Estratégia de robustez
Preferir arquitetura híbrida:
- parser determinístico para XLSX/CSV/PDF extraível;
- LLM/agente para entender colunas e contexto;
- validadores determinísticos para percentuais, prazos e duplicidade;
- Human Gate para baixa confiança;
- cache/memória de mapeamento por origem.

Assim o sistema continua funcionando mesmo quando o fornecedor muda a planilha diariamente.


## 22. IA COMO RECURSO MEDIDO E CUSTO REPASSÁVEL

### 22.1 Decisão do Owner
Os recursos de IA do Corban OS, especialmente o **Agente de Importação Comercial**, podem ter custo de uso repassado ao tenant/usuário.

A plataforma não deve absorver indefinidamente o custo variável de LLM/OCR/processamento de arquivos.

### 22.2 Modelo recomendado
Separar:
- assinatura base do Corban OS;
- franquia de IA incluída no plano, se desejado;
- consumo excedente de IA medido por uso;
- custo de terceiros + margem/configuração comercial da plataforma.

Unidades possíveis de medição:
- por arquivo processado;
- por página de PDF;
- por linha/aba de planilha processada;
- por job de importação;
- por créditos de IA;
- internamente por tokens/OCR/compute, sem expor complexidade técnica ao usuário.

### 22.3 UX recomendada
O usuário deve ver algo simples, por exemplo:
- “Este processamento consumirá aproximadamente X créditos”
- “Saldo de IA: Y créditos”
- “Processar arquivo”
- histórico de consumo por organização.

Não exibir tokens como unidade principal para usuário final.

### 22.4 Governança de custo
Antes de executar um job pago:
- estimar custo quando possível;
- aplicar limite por tenant;
- permitir orçamento/teto mensal;
- bloquear estouro não autorizado;
- registrar consumo por job;
- separar custo real do provedor, crédito cobrado e margem;
- suportar fallback de modelo mais barato quando a confiança continuar aceitável;
- não processar novamente o mesmo arquivo sem necessidade (fingerprint/cache).

### 22.5 Arquitetura
Cada job de IA deve ter metering próprio, por exemplo:
- organization_id;
- user_id;
- job_id;
- capability;
- provider/model;
- input/output usage;
- custo estimado/real;
- créditos debitados;
- status;
- timestamps;
- referência ao arquivo/importação.

Os valores financeiros devem usar NUMERIC/inteiro escalado, nunca Float.

### 22.6 Estratégia comercial possível
Exemplo:
- Plano inclui N créditos/mês;
- excedente cobrado por créditos;
- recursos simples podem usar modelos baratos;
- PDF complexo/baixa confiança pode usar modelo superior e consumir mais créditos;
- usuário pode optar por não usar IA e fazer mapeamento manual quando disponível.

A precificação final ainda é decisão comercial futura; não hardcodar valores no produto.


### 22.7 Provedor preferencial inicial — Gemini

Decisão de produto do Owner:
- Para o Agente de Importação Comercial, **Gemini deve ser o provedor preferencial inicial** devido à boa experiência prática do Owner com interpretação de dados e ao custo competitivo da API paga.
- Esta preferência **não deve criar lock-in arquitetural**.

Implementação esperada:
- camada de abstração de modelos/provedores;
- Gemini como default inicial para análise semântica de XLSX/CSV/PDF quando IA for necessária;
- fallback configurável para outros modelos/provedores;
- roteamento por custo, qualidade, tamanho de contexto e confiança;
- metering por job/tenant;
- custo do provedor separado do preço em créditos cobrado do cliente;
- possibilidade futura de trocar o modelo default sem migrar regras de negócio.

Regra:
> O Corban OS escolhe o melhor motor disponível; o domínio comercial nunca depende diretamente de um único fornecedor de IA.


## 23. AGENTE OPERACIONAL DE IA — MONITORAMENTO CONTÍNUO

### 23.1 Visão
Além do Agente de Importação Comercial, o Corban OS deve ter um **Agente Operacional de IA** responsável por observar continuamente a operação do tenant e identificar situações que exigem atenção.

O agente não substitui as regras determinísticas do sistema. Ele atua sobre eventos, métricas, SLAs e contexto operacional para:
- detectar;
- priorizar;
- explicar;
- recomendar;
- notificar;
- e, quando autorizado, executar ações reversíveis de baixo risco.

### 23.2 Áreas de monitoramento

#### Esteira / propostas
Detectar:
- proposta parada acima do SLA;
- etapa sem movimentação;
- proposta aguardando documento;
- proposta aguardando retorno do banco/provedor;
- proposta aprovada sem continuidade;
- proposta paga sem conciliação/comissão esperada;
- proposta com status conflitante entre banco, cliente e empresa;
- concentração anormal de propostas em uma etapa.

Exemplo:
```text
"A proposta 123 está há 19h em Aguardando Documento.
SLA esperado: 4h.
Última ação: solicitação de contracheque.
Responsável: operador X."
```

#### Ociosidade comercial
Detectar:
- lead sem contato;
- cliente sem follow-up;
- operador sem atividade relevante;
- fila sem responsável;
- carteira parada;
- queda abrupta de conversão;
- oportunidade sem retorno dentro da janela definida.

Ociosidade deve ser baseada em métricas operacionais configuráveis, não em inferências subjetivas sobre capacidade ou desempenho pessoal.

#### Documentos
Detectar:
- checklist incompleto;
- documento vencido;
- arquivo ilegível ou inconsistente;
- ausência de documento obrigatório;
- documentos enviados sem vínculo com proposta/cliente.

#### Comissões
Detectar:
- comissão esperada sem recebimento;
- valor recebido divergente da condição comercial;
- repasse acima da comissão disponível;
- regra de grupo ausente;
- comissão sem grupo vinculado;
- divergência entre tabela publicada e evento financeiro;
- possível clawback/reversão sem tratamento.

O agente nunca inventa valor de comissão; toda conclusão deve partir de fonte de verdade e evidência financeira.

#### Integrações / workers
Detectar:
- job falhando repetidamente;
- integração sem resposta;
- fila crescente;
- webhook órfão;
- credencial/provider indisponível;
- importação travada;
- erro recorrente por fornecedor.

#### Catálogo comercial
Detectar:
- tabela vencendo;
- tabela vencida ainda ativa;
- prazo sem coeficiente;
- comissão ausente;
- origem da produção não definida;
- tipo de contrato sem condição comercial;
- tabela duplicada ou muito semelhante;
- mudança relevante em arquivo importado em relação ao padrão anterior.

#### Equipe / operação
Detectar:
- tarefas sem dono;
- excesso de itens numa mesma carteira;
- supervisor/gerente sem regra aplicável quando exigida;
- usuário revogado ainda referenciado em fluxo;
- fila operacional desbalanceada.

### 23.3 Arquitetura recomendada

```text
Eventos do sistema
        ↓
Motor determinístico de regras/SLA
        ↓
Agregador operacional
        ↓
Agente IA
        ↓
Classificação + prioridade + explicação
        ↓
Action Center
        ↓
Notificação / sugestão / ação permitida
```

A IA interpreta contexto e prioriza. Regras críticas continuam determinísticas.

### 23.4 Níveis de autonomia

#### Nível 1 — Observar
Somente detectar e registrar.

#### Nível 2 — Recomendar
Sugere a próxima ação:
- cobrar documento;
- reatribuir fila;
- revisar tabela;
- confirmar comissão;
- reprocessar integração.

#### Nível 3 — Executar ação reversível
Quando autorizado pelo tenant:
- criar tarefa;
- enviar lembrete interno;
- reabrir item;
- reatribuir responsável;
- agendar follow-up;
- reprocessar job idempotente.

#### Nível 4 — Human Gate obrigatório
Sempre exigir humano para:
- alterar comissão;
- publicar tabela;
- aprovar condição financeira;
- enviar comunicação externa sensível;
- excluir dados;
- alterar regra de repasse;
- movimentar dinheiro;
- executar ação irreversível.

### 23.5 Action Center
O agente deve alimentar uma central única de atenção, por exemplo:

```text
CRÍTICO
- 3 propostas pagas sem comissão reconciliada

ALTO
- 12 propostas acima do SLA
- integração 2Tech falhou 4 vezes

MÉDIO
- 8 clientes sem follow-up há 24h

BAIXO
- tabela do Banco X vence em 5 dias
```

Cada alerta deve mostrar:
- por que foi criado;
- evidências;
- impacto;
- responsável;
- ação recomendada;
- opção de resolver/ignorar/adiar;
- histórico de decisões.

### 23.6 Custo de IA
Aplicar a mesma política de metering:
- tarefas simples e recorrentes devem usar regras determinísticas sem custo de LLM;
- IA só entra quando contexto/semântica agregam valor;
- processamentos podem consumir créditos do tenant;
- evitar analisar o mesmo evento repetidamente;
- usar cache, sumarização incremental e roteamento de modelo.

Gemini pode ser o provedor inicial preferencial também aqui, sem lock-in.

### 23.7 Guardrails
O agente operacional não deve:
- decidir aprovação de crédito;
- inferir atributos sensíveis de clientes;
- discriminar ou priorizar clientes com base em características protegidas;
- inventar dados;
- alterar histórico financeiro;
- publicar tabela/comissão sem gate;
- substituir controles transacionais;
- agir sem trilha de auditoria.

### 23.8 Objetivo de produto
Transformar o Corban OS de um sistema passivo, que apenas armazena dados, em um **sistema operacional ativo**, capaz de perceber gargalos e chamar atenção para o que precisa ser resolvido antes que vire perda de receita.


## 24. UX REFINEMENT — INSTITUIÇÃO / ORIGEM E RELAÇÃO COMERCIAL

Correction from the Owner after reviewing the live tenant screen:

The prior interpretation that NASP was merely a third-party partner of Smart was **wrong**.

Business reality for the Smart operation:
- Daycoval is a bank/institution;
- NASP is treated operationally by the Owner as an institution/origin equivalent to the "bank side" of the commercial setup;
- **Smart Promotora is the correspondent of NASP**, not the other way around;
- Efetiva Mais can be an external commercial origin/master depending on the specific route.

Therefore the model must separate two concepts:

1. **Who is the upstream institution/origin of the operation**
   - bank;
   - institution;
   - entity treated operationally as the primary commercial origin by the tenant (example: NASP).

2. **What is the commercial relationship between companies**
   - Smart may be Correspondente/Sub/Parceiro of an upstream entity;
   - the relationship direction matters;
   - never infer that an upstream entity is "partner of Smart" simply because it is not a traditional bank.

UX rule:
- Do not force the first list to mean "regulated bank only".
- Prefer a broader user-facing concept such as **"Instituições / Origens"** when the tenant's operation includes entities like NASP.
- Relationship labels must express direction, e.g.:
  - "Smart Promotora é Correspondente de NASP";
  - "Smart Promotora é Sub de X";
  - "Smart Promotora opera diretamente com Banco Y".
- The system must not silently reclassify NASP away from the current list based on a legal/category assumption.

Production-origin semantics still apply to the table/route:
- Própria = operation belongs to the tenant's own production, including when the tenant operates as Master/Sub in its own production flow;
- Terceiro = table/production comes from an external company/origin for that route.

Do not collapse:
- institution/origin,
- commercial relationship role,
- production origin.

These are distinct dimensions.


## 25. UX DO CATÁLOGO — CADASTRO NÃO DEVE VIRAR LISTA INFINITA

Feedback do Owner após usar a tela LIVE:

### Problema observado
A tela atual coloca **Bancos** e **Provedores/Masters** no mesmo bloco e exibe os registros cadastrados diretamente acima dos formulários. Isso causa dois problemas:
1. mistura conceitos diferentes e induz erro de classificação;
2. conforme o tenant cadastra mais entidades, o bloco cresce indefinidamente e vira uma lista longa, prejudicando o uso diário.

### Decisão de UX
A tela principal `/app/comercial` deve funcionar como **onboarding/resumo**, não como listagem completa de cadastros.

Não exibir listas crescentes de bancos/provedores diretamente no bloco principal.

Em vez disso, mostrar cards/resumos como:

```text
Instituições / Origens
8 cadastradas · 6 ativas
[Gerenciar] [Cadastrar]

Empresas de origem de terceiros
4 cadastradas · 3 ativas
[Gerenciar] [Cadastrar]
```

### Gerenciamento dedicado
Cada domínio deve possuir uma área própria de gerenciamento, preferencialmente página dedicada (ou drawer/modal apenas para criação/edição rápida), com:
- busca;
- filtro Ativos / Inativos / Todos;
- paginação ou lista compacta;
- editar;
- inativar;
- reativar/habilitar;
- visualizar vínculos/uso;
- excluir apenas quando não houver dependências e houver confirmação explícita.

Sugestão de rotas:
- `/app/comercial/instituicoes`
- `/app/comercial/origens`

### Separação visual obrigatória
Não colocar Banco/Instituição e Provedor/Master no mesmo card de cadastro.

A UI deve deixar claro:
- **Instituições / Origens** = lado upstream da operação (ex.: Daycoval, NASP, Hope, conforme realidade operacional do tenant);
- **Empresas de origem de terceiros** = empresa externa usada quando a produção é de terceiro (ex.: Lev, Efetiva Mais, Bevi, conforme a rota).

A relação comercial (Correspondente/Sub/Master/Parceiro) é outra dimensão e não deve ser confundida com o tipo da entidade.

### Padrão de cadastro
Fluxo recomendado:
1. usuário clica `Cadastrar`;
2. formulário curto abre;
3. salva;
4. retorna ao resumo/gerenciador;
5. o registro aparece na área de gerenciamento, não expandindo o bloco da tela principal.

### Regra de escalabilidade de UX
Nenhum cadastro que possa crescer para dezenas/centenas de registros deve renderizar todos os itens diretamente no onboarding principal.


## 26. UX DO CATÁLOGO — CONVÊNIOS

Feedback do Owner após uso da tela LIVE:

### Problemas observados
1. O botão para cadastrar/habilitar outro convênio não está visualmente sugestivo; parece apagado/desabilitado mesmo quando deveria representar uma ação disponível.
2. O bloco segue a mesma lógica ruim observada em bancos/origens: cada novo convênio aparece diretamente na tela principal, fazendo a lista crescer indefinidamente.

### Decisão de UX
Aplicar aos Convênios o mesmo padrão de gerenciamento adotado para Instituições/Origens.

Na tela principal `/app/comercial`:
- não listar todos os convênios;
- mostrar apenas resumo, por exemplo:
  - `12 convênios cadastrados · 8 ativos`;
- botões de ação visualmente claros:
  - `Cadastrar convênio`
  - `Gerenciar convênios`
  - opcionalmente `Habilitar da base nacional`.

### Área dedicada
Criar uma tela dedicada, por exemplo:
- `/app/comercial/convenios`

Ela deve permitir:
- busca;
- filtro Ativos / Inativos / Todos;
- origem: Nacional / Próprio;
- habilitar convênio da base nacional;
- cadastrar convênio próprio;
- editar dados permitidos;
- inativar;
- reativar;
- visualizar vínculos com tabelas/rotas;
- excluir somente quando não houver dependências e com confirmação explícita.

### Ação visual
Botões primários de cadastro/habilitação não podem parecer desabilitados.
Devem ter contraste, rótulo inequívoco e estado hover/focus claro.

Evitar ação genérica como `+` ou texto apagado quando a intenção é `Cadastrar outro convênio`.

### Regra geral
Aplicar este padrão de gerenciamento também aos demais cadastros que crescem:
- instituições/origens;
- empresas de origem de terceiros;
- convênios;
- grupos de comissão;
- produtos/tabelas.

A tela principal de Comercial deve ser um painel de progresso e resumo, não um CRUD longo.


## 27. UX DE COMISSÕES — ALINHAMENTO COM 2TECH E IMPORTAÇÃO EM MASSA

Feedback do Owner após usar a tela LIVE e comparar com o material já fornecido da 2Tech.

### 27.1 Problema atual — Grupo de Comissão
A tela atual pede:
- Nome do grupo;
- Tipo do grupo (Corretor, Parceiro, Indicador etc.);
- Base fixa de cálculo (% sobre produção ou % sobre comissão recebida).

Isso ficou confuso para o Owner e não representa bem o benchmark funcional da 2Tech.

No material 2Tech, o conceito relevante do Grupo de Comissão é:
- Nome;
- Regra;
- componentes de comissão/referência (ex.: À Vista/Diferido, Bônus, Fixos);
- coluna/campo de referência;
- percentual distribuído;
- regras opcionais de gerente/supervisor e respectivas bases.

### 27.2 Decisão de UX
**Tipo do grupo não deve ser uma escolha obrigatória do usuário.**

O nome do grupo já expressa a finalidade operacional:
- Corretor;
- Parceiro;
- Balcão;
- Indicador;
- Funcionário;
- Time de Vendas;
- outro criado pelo tenant.

Se uma classificação técnica for necessária internamente, ela deve ser opcional/automática e não bloquear o cadastro.

A **base de cálculo também não deve ficar rigidamente presa ao grupo inteiro**. Ela pertence à regra/componente de comissão aplicável.

Exemplo:
```text
Grupo: Corretores

Regra:
Comissão à vista
Campo de referência: Comissão recebida
Distribuição: 65%

Bônus
Campo de referência: Bônus recebido
Distribuição: 50%
```

Assim um mesmo grupo pode ter regras distintas por componente, sem deformar a identidade do grupo.

### 27.3 Política de Repasse
A tela separada atual "Política de repasse" ficou abstrata para o Owner.

Ela deve ser apresentada como **regra padrão de comissão/repasse**, reutilizável, mas não como etapa conceitual obrigatória antes de cadastrar tabela.

UX preferida:
- o usuário cria o grupo;
- define sua regra padrão quando quiser;
- ao cadastrar/importar uma tabela, o sistema pode aplicar essa regra automaticamente;
- também pode sobrescrever a regra em uma condição específica, com auditoria.

Evitar obrigar o usuário a entender termos internos como:
- base bruta;
- base líquida;
- tipo técnico do grupo;
- policy version;
quando isso não for necessário à operação normal.

Esses detalhes podem ficar em "Configuração avançada".

### 27.4 Onde informar os percentuais da tabela
Os percentuais devem estar visíveis no contexto da **Tabela de Condições**, não escondidos em outra etapa.

Ao abrir uma tabela/versão, o usuário deve enxergar uma grade equivalente a:

| Tipo Contrato | Prazo | Coeficiente | Taxa | Comissão recebida | Corretor | Parceiro | Balcão | Indicador |
|---|---:|---:|---:|---:|---:|---:|---:|---:|

Cada Grupo de Comissão ativo vira uma coluna dinâmica.

O usuário pode:
- editar manualmente uma célula;
- aplicar regra padrão;
- importar várias linhas;
- revisar antes de publicar.

### 27.5 Importação em massa
O Corban OS **já possui backend para importação CSV/XLSX em lote e RPC atômica LIVE**, porém a UI atual deixa isso escondido dentro da versão rascunho da tabela, o que faz parecer que só existe cadastro manual.

Decisão:
- tornar a importação uma ação principal e visível da Tabela de Condições;
- botões claros:
  - `Importar planilha`
  - `Adicionar condição manualmente`
- após upload:
  - prévia;
  - mapeamento de colunas;
  - aplicação das regras dos grupos;
  - validação;
  - importar em lote;
  - relatório de aceitas/rejeitadas.

A importação deve suportar CSV/XLSX agora; PDF entrará pelo Agente de Importação IA.

### 27.6 Benchmark 2Tech — princípio a preservar
Não copiar a interface da 2Tech literalmente, mas preservar o princípio observado:
- grupo guarda regra de distribuição;
- regras podem ter múltiplos componentes/referências;
- tabela é cadastrada/importada uma vez;
- grupos aparecem como colunas/saídas da mesma condição;
- não repetir a tabela uma vez por grupo;
- cadastro em massa deve ser caminho de primeira classe, não recurso escondido.


## Empresa de origem — classificação editável
Decisão do Owner: a classificação de uma empresa de origem de terceiros não é definitiva no cadastro.

Exemplo:
- cadastrar inicialmente como Correspondente;
- depois corrigir para Promotora.

Regra de UX:
- o gerenciador de empresas de origem deve permitir editar **nome + classificação**;
- classificações atuais: Banco direto, Master, Promotora, Correspondente, Parceiro, Outro;
- editar a classificação não muda automaticamente a direção da relação comercial nem a origem da produção das tabelas;
- alterações históricas sensíveis devem continuar auditáveis quando houver vínculo financeiro/contratual.
