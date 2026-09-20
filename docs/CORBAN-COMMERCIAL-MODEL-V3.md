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
