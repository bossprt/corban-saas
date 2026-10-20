# CHANGELOG — CORBAN ENTERPRISE

Todas as mudanças notáveis deste projeto são documentadas aqui.

**Formato:** [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
**Versionamento:** [SemVer](https://semver.org/lang/pt-BR/)
**Compatível com Master:** v1.1

**Regras:**
- Toda sessão de trabalho deve adicionar uma entrada em `[Unreleased]` ou em uma nova versão.
- Entradas usam as categorias: `Adicionado`, `Alterado`, `Corrigido`, `Removido`, `Segurança`, `Depreciado`.
- Nunca editar entradas antigas — adicionar nova entrada.

---

## [Unreleased]

### Ranking de vendas e painel da equipe, com modo TV (21/10/2026)
- Adicionado (plano fase 2; dono escolheu: a equipe toda vê o ranking): Vendas > Ranking. Por período (hoje, 7 dias, mês, ano) e por produção paga (valor liberado dos pagos ao cliente) ou digitada (cadastrados, sem cancelados/recusados): pódio, tabela por vendedor com contratos e % da meta do mês, total, ticket médio, meta da equipe, funil (leads → digitados → pagos) e últimos pagos ao cliente. Comissão e repasse nunca aparecem. "Modo TV" ocupa a tela e atualiza a cada minuto. Corretor externo não vê. `20261021120000_sales_ranking_v1`, teste `sales-ranking-contract.sql`.

### Relatório de comissão: a prévia mostra todas as linhas (20/10/2026)
- Alterado (dono: "por que a tela só mostra 5 contratos?"): a prévia da importação mostrava só 5 linhas de amostra; agora mostra todas (até 1.000), com rolagem e a contagem "Prévia: X linha(s)".

### Relatório de comissão: aviso antes de importar (20/10/2026)
- Adicionado (dono: "pq o sistema não avisou? ... o arquivo possui X contratos e os contratos não podem ser importados porque não possuem vendedor"): ao escolher a coluna do contrato, a tela confere cada número do arquivo com a mesma regra da importação e diz quantos estão prontos e, por grupo, os que têm pendência (sem vendedor, sem comissão calculada, já recebida, não encontrado, repetido), com o link para os contratos sem vendedor. O botão vira "Importar mesmo assim" quando há pendência. No relatório importado, a linha "Sem comissão calculada" diz quando o contrato está sem vendedor. `20261020202219_receipt_file_check_v1`, teste `receipt-file-check-contract.sql`.

### WorkBank: "PREF. RIO BRANCO APO" usa a tabela de Efetivo (20/10/2026)
- Corrigido (dono: "é a mesma para efetivos"): a importação do relatório WorkBank recusava os aposentados da Prefeitura de Rio Branco ("Tabela não encontrada"); agora usam a tabela "PROSESP - Pref. Rio Branco - Efetivo".

### Importação de contratos atualiza a etapa dos que já existem (20/10/2026)
- Alterado (pedido do dono, relatório WorkBank da PROSESP: 4 contratos "Em análise" no Corban já estavam CONCRETIZADO no banco): ao importar, um contrato que já existe segue a situação do relatório, só para frente ("Em análise" e "Pendência" podem trocar). Paga, Cancelada e Recusada nunca mudam; CANCELADA no arquivo cancela um contrato ainda não pago; contrato Pago com CANCELADA no arquivo vira aviso para conferir. Valores, vendedor e comissão nunca mudam pelo arquivo. A prévia mostra "vai mudar de X para Y"; a mudança fica no histórico da esteira como "Pelo relatório do banco". Só tela, sem migration (`src/lib/imports/report-move.ts`, teste `report-move.test.ts`).

### Vendas (CRM), fase 1: tarefas, etapas da empresa, leads parados e "Não perturbe" (20/10/2026)
- Adicionado (pedido do dono: "profissionalizar esse CRM", depois do comparativo com o mercado): tarefas por lead (ligação, WhatsApp, visita, e-mail, outro), com data, responsável e resultado ao concluir; "Registrar contato" grava um contato já feito com o resultado e pode marcar o próximo. O próximo contato do lead é a tarefa aberta mais próxima; os retornos marcados antes viraram tarefas. A tela Hoje mostra "Minhas tarefas".
- Adicionado: etapas da empresa (Vendas > Etapas, supervisor) dentro de Novo, Em contato e Negociando; o quadro mostra as colunas da empresa. Proposta, Ganho e Perdido continuam fixos (seguem a proposta).
- Adicionado: Leads parados (supervisor): leads com vendedor sem movimento há N dias e sem tarefa à frente; passar para outro vendedor ou devolver para a fila. Lead passado para outro vendedor leva as tarefas abertas.
- Adicionado (dono: "o que mais se usa é o telefone no Não perturbe"; os bancos mandam lista): lista "Não perturbe" da empresa, com marca no lead, cadastro de um número e importação da lista do banco (só a coluna de telefone sai do computador). O quadro e o lead avisam; o lead sai da fila; nada é bloqueado. A consulta ao Lemit entra na mesma lista quando houver a documentação.
- Migration `20261020163941_crm_followup_v1` (ADR-0062); teste `crm-followup-contract.sql` (38 verificações).

### Data de "hoje" em Brasília, segurança fina e testes em dia (19/10/2026)
- Corrigido (achado nos testes, dono aprovou): o banco roda em UTC; entre 21h e meia-noite de Brasília, "hoje" já era amanhã em 30 funções (mover para Paga sem data gravava amanhã, data paga de amanhã era aceita, lançamentos de repasse/financeiro podiam ficar com data de amanhã). Essas funções agora rodam no fuso de São Paulo; a conta bancária nova usa a data de Brasília (`20261020031521_sao_paulo_today_v1`, teste `sao-paulo-today-contract.sql` que falha se uma função voltar a ler "hoje" sem o fuso).
- Segurança: anon não executa mais 5 funções internas nem lê as tabelas de termos (nenhuma era alcançável na prática); `pay_account_in_batch` confere a permissão por conta própria (`20261020031458_grants_hygiene_v2`).
- Testes: os 81 contratos SQL passam no banco local recriado (9 desatualizados corrigidos: data de Brasília, vendedor diário por padrão, grupo obrigatório, fixtures próprias; os que precisam de migration em /tmp documentam o `docker cp`).

### Lote de pagamento: detalhes de cada contrato pago (17/10/2026)
- Alterado (pedido do dono: detalhar os contratos pagos dentro de cada valor; escolheu a opção 1): no lote de pagamento (tela e Excel), cada contrato mostra banco, convênio, produto (tipo de contrato), valor liberado ao cliente e data em que foi pago ao cliente. O Excel ganhou essas colunas e "Pago em parte".
- Adicionado: o pagamento do saldo ("Saque do saldo", ainda não usado em 17/10) lista os contratos que o valor pagou, dos mais antigos para os mais novos, com "pago em parte"; a soma bate com o valor pago. Só leitura, nada é gravado (ADR-0061, `20261017190216_payout_batch_contract_details_v1`).

### Dashboard: cada número abre só os contratos dele (17/10/2026)
- Corrigido (pedido do dono: "Esteira agora" mostrava a esteira inteira e não só as 2 pendências): os números de "Esteira agora" abrem a Esteira filtrada pela situação (`/app/propostas?estado=`), com a aba da etapa marcada.
- Corrigido: "Contratos parados além do prazo da etapa" abre só os parados (`/app/propostas?atrasado=1`), não mais a Operação inteira.
- Corrigido: "Banco não pagou há mais de 30 dias" abre só os pagos ao cliente há mais de 30 dias (antes listava todos os que esperam o banco).
- Corrigido: "Recebido dos bancos" abre a Conciliação só com o recebido no período escolhido (`?de=&ate=`).
- Corrigido: "Sem vendedor" e "Sem banco" abrem só os contratos sem vendedor ou sem banco; os filtros de Contratos ganharam essas opções.

### Corretor externo: extrato sem pagamento desfeito e sem "Sugerir melhoria" (14/10/2026)
- Alterado (pedido do dono: "essas informações só abrem brecha para questionamentos"): no Extrato, quem não é do financeiro não vê o pagamento desfeito nem os 2 lançamentos dele (pagamento e ajuste); vê os pagamentos feitos e os estornos. O financeiro continua vendo tudo.
- Alterado: o corretor externo (portal) não tem mais o botão "Sugerir melhoria"; a página e o envio também recusam (só os usuários da empresa sugerem).

### Banco local de teste recriado (14/10/2026)
- Adicionado `scripts/f0/rebuild-local.sh`: recria o banco local de teste do zero (baseline de produção + migrations; pula e lista as migrations de dados da Smart). Seed de teste não liga o vendedor ao usuário antes de ele ser membro da empresa (falhava em banco novo). Sem mudança em produção.

### Relatório de comissão marca o contrato como pago ao cliente (14/10/2026)
- Alterado (pedido do dono: o contrato da Dandara só liberou o repasse depois de mexer na esteira, embora o banco já tivesse pago a comissão): ao confirmar um relatório de comissão, cada contrato do relatório que ainda não estava em "Paga" vai para "Paga" (pago ao cliente) com a data em que o banco pagou, e a parte do vendedor é liberada na hora (o pagamento continua manual no Repasse). Só contratos com vendedor e comissão calculada; os outros ficam como estão e aparecem no quadro "Conferir" da tela do relatório. Relatório de estorno não muda contrato. A esteira registra "Pago ao cliente pelo relatório de comissão <arquivo>". Os 2 contratos PROSESP que já tinham a comissão recebida e continuavam em análise (Acerto da Produção 8 e 10) foram passados para pago ao cliente: R$ 176,00 e R$ 150,00 liberados aos vendedores. Migrations `20261014162354_commission_report_marks_paid_v1` e `20261014162359_commission_report_paid_backfill_v1` (aplicadas em produção; ADR-0060), contrato `tests/security/commission-report-marks-paid-contract.sql` (7/7); `seller-credit` e `commission-receipts` ajustados à regra nova.

### Contratos: comissão recebida lançada à mão (14/10/2026)
- Adicionado (pedido do dono: Gratificação "a que a empresa vai receber deverá ter a opção % ou R$ e basicamente sempre será manual"; base escolhida contrato por contrato): na setinha de Contratos, "Alterar/Ver comissão", o administrador lança a comissão recebida de um contrato (Gratificação ou outra) como % sobre o líquido, % sobre o bruto ou R$, com motivo; o contrato é recalculado na hora e o lançamento aparece com "Remover" (com motivo). Substitui o que a tabela diz para essa comissão naquele contrato; a parte do vendedor continua programada na tabela. Histórico do contrato mostra cada lançamento; os lançamentos nunca são alterados nem apagados. Recusado em contrato recusado/cancelado ou já pago ao vendedor; se a nova conta não fecha (repasse acima do recebido), nada é gravado. Antes de valer, os 22 contratos calculados em produção foram recalculados sem gravar com o motor novo: resultado idêntico. Migration `20261014053535_manual_received_commission_v1` (aplicada em produção, md5 conferido; ADR-0059), contrato `tests/security/manual-received-commission-contract.sql` (16/16).

### Comissão: Gratificação (14/10/2026)
- Adicionado (pedido do dono, "igual ao Bônus"): tipo de comissão "Gratificação", paga uma vez, em todas as telas que listam as comissões (grupos, tabelas, importação de tabelas, cálculo e contratos). Os 5 grupos da Smart (Balcão, Parceiro, Corretor, Call Center, Afiliado) ganharam nova versão da regra com a Gratificação igual ao Bônus de cada um; depois, a pedido do dono, também os 4 grupos da MAIS VALOR (Corretor, Balcão, Afiliado, Parceiro), igual ao Bônus de cada um (`20261014052220_commission_gratification_mais_valor_v1`, md5 conferido). Importação inteligente de tabelas reconhece a coluna "Gratificação". Migration `20261014052051_commission_gratification_v1` (ensaiada sem gravar, aplicada em produção 14/10/2026, md5 conferido).

### Repasse: Lotes de pagamento (13/10/2026)
- Adicionado (pedido do dono, como no NASP): cada "Confirmar pagos" vira um lote. Repasse > "Lotes de pagamento": data, quantidade, valor total, conta que pagou, comprovante, quem pagou e situação (Pago, Desfeito, Desfeito em parte). O lote mostra cada pessoa paga com os contratos (ADE, cliente, valor por contrato), Excel e Imprimir/PDF, e "Desfazer lote" (administrador, com motivo) desfaz todos os pagamentos ainda pagos de uma vez, pelo mesmo caminho do "Desfazer pagamento". Pagamento de uma pessoa só vira um lote dela. Pagamentos antigos agrupados em 7 lotes (quem pagou, data, comprovante e minuto), entre eles o de 06/10 com 9 vendedores e os dois de 13/10 (um desfeito). Ensaiada em produção sem gravar. Migration `20261014000452_payout_batches_v1` (aplicada em produção, md5 conferido; ADR-0058), contrato `tests/security/payout-batches-contract.sql` (16/16).

### Pagar vendedores: QR Code só dos marcados (13/10/2026)
- Corrigido (dono: com 5 de 6 marcados, "Pagar com QR Code" mostrou os 6): a sequência de QR Codes passa a ter só os vendedores marcados, fixada ao abrir; o botão mostra quantos ("Pagar marcados com QR Code (5)") e fica desligado sem nenhum marcado. O QR Code de uma linha não marcada abre sozinho, sem entrar na sequência.

### Repasse: Desfazer pagamento (13/10/2026)
- Adicionado (pedido do dono: pagou 5 vendedores no Corban, R$ 1.009,48, sem fazer o PIX): botão "Desfazer pagamento" nos repasses pagos da conta de cada pessoa, só para administrador, com motivo. Nada é apagado: o repasse fica "Pagamento desfeito" (quem, quando, motivo), os lançamentos que ele fechou voltam a ficar abertos, um crédito "Pagamento desfeito" anula o débito do pagamento no extrato, e a saída da conta bancária da empresa é cancelada com o motivo no histórico. Só o último pagamento da pessoa, e não se a saída já foi conciliada com o extrato do banco. Os contratos voltam a "não pago ao vendedor". Migration `20261013230214_payout_reversal_v1` (aplicada em produção 13/10/2026, md5 conferido; ADR-0057). Usado nos 5 pagamentos de 13/10 (R$ 1.009,48): desfeitos, saldo e valor a pagar de volta, saídas do banco canceladas, contrato `tests/security/payout-reversal-contract.sql` (17/17).

### Importação PROSESP: situações ANDAMENTO e CONFERÊNCIA (13/10/2026)
- Corrigido (dono: "os dois estão em análise"): na planilha WorkBank (PROSESP), as situações "ANDAMENTO" e "CONFERÊNCIA" entram como Em análise no banco. Antes eram recusadas com "Etapa não reconhecida".
- Corrigido: na conferência da importação de contratos, uma situação não reconhecida aparecia como "Automática" (o rótulo de quando a planilha não tem etapa). Agora a tela mostra o texto da planilha. Teste em `tests/unit/contract-import.test.ts`.

### PROSESP: novo de 12 meses no Governo do Acre - Temporário (13/10/2026)
- Adicionado (decisão do dono: "são novos de 12 meses, 8%"): a planilha de produção PROSESP (WorkBank) trouxe contratos novos de 12 meses, recusados na conferência ("Prazo 12 fora da tabela (4 a 5, 6 a 8)"). A tabela "PROSESP - Governo do Acre - Temporário" ganhou vigência nova desde 01/01/2026 com linha de novo para 12 meses igual à de 6 a 8 meses (8% à vista sobre o líquido; repasse Balcão 4, Corretor 3, Parceiro 3, Call Center 2, Afiliado 0,8). A vigência anterior fica no histórico. As linhas antigas da PROSESP têm origem "converted", que a função de repasse não aceita: a linha nova vai como "manual". Ensaiada em produção sem gravar. Migration `20261013194510_prosesp_temporario_novo_12_v1` (aplicada em produção 13/10/2026, md5 conferido).

### NASP: base da comissão por tipo (13/10/2026)
- Corrigido (regra do dono: novo e refinanciamento sobre o líquido, compra de dívida sobre o bruto): a API de contratos gravava só o bruto (como valor liberado), então linha sobre o líquido calculava sobre o bruto (refinanciamento pagaria a mais). Agora `valor_liberado` (bruto) vira o valor do contrato e `valor_liquido_cliente` o valor liberado (sem ele, o bruto; líquido acima do bruto é recusado). Catálogo: as duas linhas de compra de dívida ainda sobre o líquido (Governo "COMPRA NORMAL" e Prefeitura "Normal - Efetivo / Pensionista") ganharam vigência nova desde 01/01/2026 sobre o bruto; contratos já cadastrados mantêm o cálculo. Ensaiada em produção sem gravar. Migration `20261013055148_nasp_commission_base_v1` (aplicada em produção 13/10/2026, md5 conferido), contrato `tests/security/api-contracts-contract.sql` (31/31).

### NASP: compra de dívida nas tabelas Temporário e Comissionado (13/10/2026)
- Adicionado (decisão do dono: "igual ao novo, a comissão é no bruto"): o primeiro envio do NASP pela API trouxe 4 contratos Pagos certos e 1 compra de dívida recusada (table_not_found), porque as tabelas Temporário e Comissionado só tinham novo e refinanciamento. As 8 tabelas (4 Governo do Acre, 4 Prefeitura de Rio Branco) ganharam nova vigência desde 01/01/2026 com linha de compra de dívida igual à do novo (6% nas de 4 a 7 meses, 10% nas demais, mesmo repasse por grupo), com base de cálculo no bruto. A vigência anterior fica no histórico; contratos já cadastrados mantêm o cálculo. Ensaiada em produção sem gravar antes. Migration `20261013054347_nasp_compra_divida_lines_v1` (aplicada em produção 13/10/2026, md5 conferido).

### NASP Prefeitura: tabela Normal (13/10/2026)
- Adicionado (pedido do dono: mesma regra de comissão recebida e repassada do Governo do Acre): tabela "NASP - Pref. Rio Branco - Prefeitura Normal - Efetivo / Pensionista", com novo, refinanciamento e compra de dívida (no Governo são três tabelas com a mesma regra), prazo 24 a 84, sem taxa nem imposto, comissão à vista 10% sobre o líquido, repasse Balcão 5%, Corretor 4%, Parceiro 4%, Call Center 2,5%, Afiliado 1%, vigência desde 01/01/2026. A API de contratos acha a tabela pelo nome do NASP "Prefeitura Normal - Efetivo / Pensionista". Ensaiada em produção sem gravar antes de aplicar. Migration `20261013052608_nasp_rio_branco_normal_table_v1` (aplicada em produção 13/10/2026, md5 conferido).

### API de contratos: correspondências do NASP e nomes de migrations (13/10/2026)
- Adicionado (aprovado pelo dono): correspondências de tabela da API de contratos na Smart: NASP "Normal - Efetivo / Pensionista" + refinanciamento = "NASP - Gov. Acre - REFIN - NORMAL"; + compra_divida = "NASP - Gov. Acre - COMPRA NORMAL". Conferido em produção: todas as tabelas do NASP (Gov. Acre e Prefeitura) acham a tabela do Corban para novo e refinanciamento; sem tabela no Corban: "Prefeitura Normal - Efetivo / Pensionista" e compra de dívida fora da Normal do Governo. Migration `20261013050209_nasp_table_aliases_smart_v1` (aplicada em produção 13/10/2026, md5 conferido).
- Corrigido: 4 arquivos de migration com nome provisório de setembro (`20261009_component_commissions_v1`, `20261010_tenant_contract_types_v1`, `20261011_post_seller_factors_fk_indexes_v1`, `20261012_smart_commercial_import_v1`) pareciam pendentes, mas estão aplicados em produção desde 21/09/2026 (md5 idêntico). Renomeados para as versões aplicadas (`20260921001600`, `20260921001605`, `20260921001611`, `20260921003829`); assim um banco recriado do zero aplica na ordem certa.

### API de contratos para o NASP (12/10/2026)
- Adicionado: `POST /api/v1/contracts` (ADR-0056). Outro sistema (primeiro: NASP) envia o estado completo do contrato a cada mudança de etapa; o Corban cria o contrato na primeira vez e depois acompanha ADE, valores, prazo, tabela, tipo, vendedor (se não tinha) e etapa. Mão única. Contrato localizado pelo `external_id` do remetente; chamada com `sequencia` menor ou igual à última aplicada não muda nada; contrato que já existe com o mesmo banco + ADE é ligado, não duplicado. Etapas NASP convertidas no Corban; pago, recusado ou cancelado não muda mais pela API (cancelamento depois de pago vira anotação no contrato). Tabela pela correspondência cadastrada ou pelo nome terminado em " - <tabela>" no banco; vendedor pelo nome do agente (não achado: sem vendedor e aviso). Ficha do cliente só preenche o que está vazio. Valores lidos como decimal exato (texto até o banco). Chave nova com uso "Contratos" em Configuração > API; a chave age como o administrador que a criou. Descrição em `/api/v1/openapi.json`. Migration `20261013045254_api_contracts_v1` (aplicada em produção 12/10/2026, md5 conferido), contrato `tests/security/api-contracts-contract.sql` (30/30).

### Custo da Vercel: menos montagens (09/10/2026)
- Alterado (aprovado pelo dono): o ciclo de cobrança da Vercel gastou o crédito de US$ 20 com montagem de versões (103 h de CPU, máquina Elastic que sobe até 30 vCPUs); o uso real do sistema custou ~US$ 0,37. O dono trocou a máquina de montagem para Basic (2 vCPUs). `vercel.json` ganhou `ignoreCommand`: commit que só muda documentação (`.ai/`, `*.md`) não monta versão. A atualização do CURRENT-TASK passa a ir no PR da própria entrega (metade dos merges).

### Código da tabela no banco automático (09/10/2026)
- Corrigido: o "código da tabela no banco" (que liga a Fator Price às tabelas) só tinha sido preenchido nas tabelas Daycoval existentes em 08/10; tabela criada ou importada depois (de qualquer empresa, MAIS VALOR inclusive) ficava sem ele e a importação de fatores não a achava. Agora é preenchido sozinho ao criar ou renomear (código do sistema terminando no número, ex. day-bev-745031, ou nome começando por ele, ex. "745031 - ..."); código digitado nunca é trocado. Campo "Código da tabela no banco" na tela da tabela para conferir ou corrigir. Tabelas sem código receberam pela mesma regra (35 FINTECH, pelo número do código). Migration `20261009052702_table_bank_code_auto_v1` (aplicada em produção 09/10/2026, md5 conferido; 114 tabelas com código), contrato `tests/security/table-bank-code-auto-contract.sql` (6/6).

### Velocidade: servidor das telas em São Paulo (09/10/2026)
- Alterado (aprovado pelo dono): as funções da Vercel passam a rodar em São Paulo (`gru1`, `vercel.json`), ao lado do banco (Supabase `sa-east-1`), em vez de Washington (`iad1`). Cada consulta ao banco deixa de cruzar Washington ↔ São Paulo (~0,13 s de ida e volta). Sem mudança de dados, endereço, login ou variáveis. Para voltar: remover `regions` do `vercel.json`.

### Velocidade: conferência de acesso uma vez por tela (09/10/2026)
- Alterado (dono: cliques demoram): a conferência de cada tela (usuário, empresa, termos, permissões, módulos) rodava de novo no menu, na página e em cada parte (painel, janelas), 6 consultas em fila a cada vez. Agora roda uma vez por tela (cache do React por pedido) e as 4 consultas independentes (empresa, termos, permissões, módulos) vão juntas. Medido local no painel de um lead: conferência de 4 vezes para 1; consultas ao banco de 41 para 32 (as restantes em paralelo). Regras e permissões iguais. Sem mudança no banco de dados.

### Contratos: canceladas e recusadas escondidas; formulários sempre POST (09/10/2026)
- Alterado (MEL-2026-0001, pedido do dono): em Contratos, canceladas e recusadas ficam escondidas por padrão; o botão "Mostrar canceladas e recusadas (N)" traz de volta (e "Esconder" esconde); escolhendo Cancelado ou Recusado no filtro Situação elas aparecem. Os totais do topo somam só o que está na lista.
- Segurança: o formulário de login (e outros enviados por JavaScript: definir senha, vendedor, pagar em lote, recalcular, Fator Price) não tinha método; se enviado antes de a página carregar, o navegador mandava os campos no endereço (GET), inclusive a senha. Agora todos são POST; as caixas de busca de lista ficam GET de propósito. Teste unitário garante que nenhum formulário volte a ficar sem método.

### Sugerir melhoria (08/10/2026)
- Adicionado (pedido do dono): "Sugerir melhoria" no menu de todas as telas (perto de Sair). Tipo (melhoria, erro, dúvida), título e descrição; a tela de origem vai junto; aviso para não colocar CPF nem dados de clientes. Gera protocolo (MEL-2026-0001). Cada usuário vê as suas; o administrador da empresa, todas da empresa; nenhuma empresa vê a de outra. Em /platform, "Solicitações de melhoria" de todas as empresas: situação (Recebida, Em análise, Aprovada: vai ser feita, Não será feita (com motivo), Entregue) e resposta que a empresa vê. Histórico de cada mudança; nada é apagado; até 20 pedidos por usuário por dia. Migration `20261009040423_improvement_requests_v1` (aplicada em produção 09/10/2026, md5 conferido), contrato `tests/security/improvement-requests-contract.sql` (13/13).

### Contratos: Associar proposta (08/10/2026)
- Adicionado (pedido do dono): botão "Associar proposta" em Contratos: banco, nº da proposta/ADE e/ou CPF, nome do cliente e vendedor. Quando o contrato chega ao Corban (qualquer layout de importação, cadastro, portal), o vendedor da associação entra sozinho, no lugar do vendedor da planilha (decisão do dono), com histórico no contrato; a importação avisa "Vendedor da proposta associada". Achado no mesmo banco pelo nº (ADE) e, sem nº, pelo CPF só para contrato novo (contratos antigos do cliente não mudam). Contrato que já existe com o nº recebe o vendedor na hora (recalculado). Cada associação vale uma vez; cancelar pede motivo e não apaga. Lista com aguardando, usadas e canceladas. Migration `20261009025438_proposal_seller_links_v1` (aplicada em produção 08/10/2026, md5 conferido), contrato `tests/security/proposal-seller-links-contract.sql` (10/10).

### Contratos: setinha de alterações rápidas, totais e etiquetas (08/10/2026)
- Adicionado (pedido do dono): em cada contrato da lista, uma setinha abaixo da caixinha abre um menu (Alterar vendedor, Alterar/Ver comissão ou Cadastrar comissão, Dados do contrato, Alterar ADE, Documentos, Observações, Abrir contrato completo); cada opção abre uma janela sobre a lista com o contrato escrito no topo (cliente, ADE, valor, prazo) e volta para a mesma lista e filtros. "Cadastrar comissão" mostra o motivo de não ter calculado e o campo que resolve (vendedor, linha da tabela) ou o cadastro a corrigir. Marcados: "Trocar vendedor" em vários de uma vez (cada um recalculado; contrato pago pede motivo). Totais líquido e bruto dos contratos filtrados. Etiquetas na linha: pago/não pago ao vendedor, físico (pendente, recebido, no banco), pendência. Alterar ADE: função nova (ADE de outro contrato recusada; número anterior continua achando o contrato nos relatórios; antes → depois no histórico). Migration `20261009015632_contract_ade_edit_v1` (aplicada em produção 08/10/2026, md5 conferido), contrato `tests/security/contract-ade-edit-contract.sql` (9/9).

### Esteira: "Antes da fila" em cartões, cancelar com confirmação clara (08/10/2026)
- Corrigido (dono): a tabela larga obrigava a rolar e escondia o cliente na hora de cancelar. Cada proposta virou um cartão (cliente, valor, parcela, prazo, situação e botões juntos, sem rolagem lateral). "Cancelar" abre logo abaixo a pergunta com cliente, valor, prazo, parcela e data, o motivo e "Sim, cancelar" / "Voltar". Sem mudança no banco de dados.

### Layout de importação de contratos Hope (08/10/2026)
- Adicionado (pedido do dono): em Esteira > Importar planilha, layout "Hope" para o relatório "BuscaContrato". NumeroContrato = ADE; Tabela = nome da tabela Hope; TipoContrato ("Contrato Novo", "COMBO" = Refin/Portabilidade); StatusBancoCliente "PAGO AO CLIENTE" = pago, com a data de DataStatusBancoCliente. Colunas de comissão, bônus e diferido do sistema da promotora, a empresa (NomeCorretor), o banco e o telefone mascarado são ignorados; o vendedor é escolhido no contrato. Parcela 0 vira "não informada" (vale para todos os layouts). Status diferentes de "PAGO AO CLIENTE" são recusados até serem mapeados. Sem mudança no banco de dados.

### Venda fechada vai até a fila; Esteira mostra "Antes da fila" (08/10/2026)
- Corrigido (dono testou e a proposta não aparecia na Esteira): "Venda fechada: enviar para a esteira" (painel de Vendas) e "Enviar para a esteira" (Simulações) criam a proposta, preparam o checklist de documentos do banco e, sem documento obrigatório faltando, já mandam para a Fila de digitação. Faltando documento ou sem lista de documentos do banco, a mensagem diz o que falta.
- Adicionado: na Esteira, bloco "Antes da fila" com as propostas em rascunho, documentos pendentes ou prontas para digitação, com o próximo passo (preparar documentos, anexar, enviar) e "Cancelar" com motivo. Cancelar não apaga: a proposta fica cancelada no histórico, o motivo vira anotação do contrato e o lead volta para Negociando. Migration `20261008200952_cancel_proposal_before_queue_v1` (aplicada em produção 08/10/2026, md5 conferido), contrato `tests/security/cancel-proposal-before-queue-contract.sql` (8/8).

### Vendas: lead no painel lateral (08/10/2026)
- Adicionado (pedido do dono): no quadro de Vendas, o card abre o lead num painel à direita, sem sair do quadro (filtros mantidos; fechar volta ao quadro). Abas: Resumo (dados, próximo contato, etapa, histórico, vendedor), Simular (o simulador dentro do painel, com o cliente do lead), Ficha do cliente (cadastro para alterar e salvar ali) e Propostas (as simulações gravadas do cliente = propostas negociadas, com "Venda fechada: enviar para a esteira", que cria a proposta preenchida pela simulação; o lead passa para Proposta como antes). Lead sem cliente: a aba pede o CPF e cadastra ou liga o cliente. Todas as ações do painel voltam para ele (retorno só para telas de Vendas). "Pegar próximo lead" e "Cadastrar lead" abrem o painel. Botão "Simular" no topo de Vendas e "Simulador" no menu de Vendas. A página do lead continua, com as mesmas abas. Sem mudança no banco de dados.

### Simulador: escolher a tabela (08/10/2026)
- Adicionado (pedido do dono): campo "Tabela" ao lado de convênio e operação. Padrão "Todas as tabelas"; a lista segue o convênio e a operação escolhidos e mostra só tabelas com fator (perfil de fator ou coeficiente). A mesma tabela do banco vendida por várias promotoras é uma opção só (mesmo código, mesmo fator); o resultado mostra uma linha por promotora. Cliente deixa de ser obrigatório para simular (só para gravar). Sem mudança no banco de dados.

### Campo de arquivo visível em todas as telas (08/10/2026)
- Corrigido (pedido do dono): o mesmo campo de arquivo (botão "Escolher arquivo", "ou arraste aqui" e o nome do arquivo escolhido) em documentos do cliente e da proposta, portal do corretor, extrato bancário, importar recebimentos, importar contratos, importação inteligente e base antiga. Versão compacta (`FileDrop compact`) onde o espaço é pequeno. Sem mudança no banco de dados.

### Campo de arquivo visível em Fatores (08/10/2026)
- Corrigido (pedido do dono): o campo de anexar planilha em Fatores era só um texto pequeno e passava despercebido. Agora é uma caixa com botão "Escolher arquivos do computador", "ou arraste aqui" e o nome dos arquivos escolhidos (componente `FileDrop`). "Agendado" mostra só quantos dias e até quando. Sem mudança no banco de dados.

### Importar Fator Price do banco (08/10/2026)
- Adicionado: em Cadastros > Fatores, "Importar Fator Price do banco": escolhe banco e convênio, envia uma ou mais planilhas (uma aba por tabela, uma linha por dia útil), confere na tela (código, dias, prazos, fator de hoje e as tabelas do sistema que recebem, por promotora; tabelas que ficam sem fator) e importa. O fator fica no código da tabela no banco e vale para todas as promotoras que vendem a tabela (regra do dono). Um perfil diário por código e um fator publicado por dia; importar de novo não muda nada; fator diferente para o mesmo dia vira nova revisão. Sábado, domingo e feriado não têm fator: o simulador avisa e não mostra a tabela. Tabelas ganham o campo "código da tabela no banco", preenchido para as tabelas Daycoval (código day-bev-NNNNNN ou nome começando pelo número). Migration `20261008141157_factor_price_import_v1` (aplicada em produção 08/10/2026, md5 conferido; 79 tabelas Daycoval com código), contrato `tests/security/factor-price-import-contract.sql` (10/10).

### Simulador por fator e tela de Fatores (08/10/2026)
- Adicionado: o simulador começa pelo convênio e pela operação, simula por valor ou por parcela (parcela = valor × fator; valor = parcela ÷ fator, cortado no centavo), compara todas as tabelas do convênio e mostra só as que têm fator valendo (fator diário da data, fator fixo publicado ou coeficiente da linha da tabela), a melhor primeiro. Refin e portabilidade recebem o saldo devedor e mostram o troco. "Usar esta" grava a simulação do cliente (o servidor recalcula; nada da tela é confiado) e ela vira proposta como antes. Migration `20261008060304_simulator_offers_v1` (ainda não aplicada em produção), contrato `tests/security/simulator-offers-contract.sql` (11/11).
- Adicionado: na tela de Fatores, "Valendo hoje" por perfil, alerta de perfil diário sem fator para hoje, datas agendadas, histórico de publicações, ativar e desativar perfil (desativado o simulador não usa; o histórico fica) e data de hoje já preenchida. O fator é lido como decimal exato (até 10 casas), nunca como número de ponto flutuante.

### Vendas: encerrar e excluir campanha (08/10/2026)
- Adicionado: na campanha (admin/gerente), "Encerrar campanha" (leads em aberto vão para Perdido com o motivo "Campanha encerrada", com histórico; proposta e venda ficam) e "Excluir campanha" (só se nenhum lead virou proposta ou venda; digita o nome para confirmar; apaga campanha, leads, histórico e importações; clientes ficam). Os dois ficam no histórico da equipe. Migration `20261008044621_crm_campaign_delete_close_v1` (aplicada em produção 08/10/2026, md5 conferido), contrato `tests/security/crm-campaign-delete-close-contract.sql` (11/11).

### Aceite dos termos de uso na tela (08/10/2026)
- Adicionado: o administrador da plataforma publica cada versão dos termos (texto aprovado pelo advogado) em /platform; enquanto nenhuma versão estiver publicada nada muda. Publicada uma versão, a empresa que não a aceitou vai para /termos em qualquer tela: o administrador lê e aceita em nome da empresa; os demais usuários aguardam. O aceite guarda empresa, versão, usuário, data e hora, IP, navegador e o SHA-256 do texto, e não pode ser alterado nem apagado; versão nova pede novo aceite. A plataforma mostra quais empresas aceitaram. Migration `20261008035818_terms_acceptance_v1` (aplicada em produção 08/10/2026, md5 conferido; nenhuma versão publicada), contrato `tests/security/terms-acceptance-contract.sql` (15/15).

### Plataforma: nova empresa com administrador (07/10/2026)
- Adicionado: em /platform (administrador da plataforma), "Nova empresa": nome, CNPJ, nome, e-mail e senha do primeiro administrador (senha digitada na tela, pedir nova no primeiro acesso). O login é criado confirmado e `bootstrap_organization_admin` cria a empresa com papéis, módulos e etapas padrão e a auditoria; se falhar, o login é removido. CNPJ repetido e e-mail que já tem login são recusados; nome parecido pede confirmação. O administrador cria a equipe e os vendedores da empresa dele. Sem mudança no banco de dados.
### Revisão de segurança entre empresas (07/10/2026)
- Segurança: teste de isolamento com uma segunda empresa (`tests/security/tenant-isolation-sweep.sql`): nenhuma leitura de outra empresa; 5 funções pulavam a recusa para quem não é da empresa (distribuição de leads, "recebe leads", meta do vendedor, etapa da esteira, repasse); corrigidas (ADR-0052, migration `20261008024337_caller_role_null_check_v1` aplicada em produção 07/10/2026, md5 conferido; contrato `caller-role-null-contract.sql`). Tipos de contrato próprios de outra empresa não aparecem para quem está em duas empresas.

### Repasse de 11/09 na conta C6 (07/10/2026)
- Corrigido em produção (decisão do dono): o repasse de R$ 800,00 do contrato 131259, pago em 11/09/2026 fora do Corban e lançado no financeiro em 07/10, saiu da conta C6. Só a conta do lançamento, com histórico; saldo da C6 inalterado (anterior ao saldo inicial). Migration `20261008005436_fabiola_payout_c6_v1` (md5 conferido).

### Movimentações por conta bancária (07/10/2026)
- Adicionado: Financeiro > Contas bancárias > "Ver movimentações": o que entrou e saiu da conta no período, com saldo dia a dia, totais e "Baixar Excel", para conferir com o extrato do banco (o saldo segue o mesmo cálculo do saldo da conta). Filtro "Conta bancária" em Contas a pagar e receber. Só leitura; sem mudança no banco de dados.

### Conta bancária nos recebimentos de comissão e nos repasses (07/10/2026)
- Adicionado: "Conta que recebeu" ao importar relatório de comissão e ao registrar recebimento à mão; "Conta que pagou" em Pagar vendedores (lote) e Pagar agora. Opcional; vem marcada a última conta usada. O lançamento do financeiro passa a dizer a conta, com histórico (de / para); valores e datas não mudam.
- Corrigido em produção (decisão do dono): os recebimentos de comissão e os repasses já lançados da Smart, sem conta, foram para a conta C6, com histórico. Migration `20261008001318_fin_bank_account_receipts_payouts_v1` (aplicada em produção 07/10/2026, md5 conferido; 33 recebimentos e 11 repasses na C6), contrato `tests/security/fin-bank-account-contract.sql` (11/11).

### Layout de importação FINTECH CORBAN (07/10/2026)
- Adicionado: layout "FINTECH CORBAN" em Importar contratos, para o relatório de produção do banco. Id = nº do contrato no banco; a tabela vem do IdTableComissao (Id Tabela Principal guardado nas tabelas do FINTECH); ValorLiquido / ValorOperacao / ValorParcela, Prazo, cliente (CPF, nome, nascimento, celular); "FINALIZADA / PAGA" = pago ao cliente na DataFinalização. Status desconhecido não é adivinhado. Colunas da equipe do banco e de controle ficam de fora; o vendedor é informado no contrato. Sem mudança no banco de dados.

### Faixa de valor nas tabelas (07/10/2026)
- Alterado: a faixa de valor de uma linha de tabela compara com o valor liberado quando a comissão é sobre o líquido, e com o valor do contrato quando é sobre o bruto (ADR-0051). Os 13 contratos da PROSESP com faixa continuam na mesma linha.
- Adicionado: a importação de tabelas lê "Valor Inicial" e "Valor Final"; o modelo e a exportação têm as duas colunas, e tabelas com faixa passam a ser exportadas. Linha sem taxa ou coeficiente é aceita. Migration `20261007194442_table_amount_ranges_v1` (aplicada em produção 07/10/2026, md5 conferido), contrato `tests/security/table-amount-ranges-contract.sql` (9/9).

### FINTECH CORBAN: 35 tabelas (07/10/2026)
- Adicionado: 35 tabelas do FINTECH CORBAN na Smart, produção própria, sem IR e sem imposto, a partir da exportação do banco: FGTS (BFFUNDO, FLEX, FIXO e J17 - FIXO), CLT Privado (C e C-Seguro) e INSS (Novo, Port + Refin, Portabilidade Pura e Entrada). 61 linhas com faixa de prazo e de valor; base bruta onde o banco diz "Valor Bruto", líquida no resto; repasse Corretor 65%, Parceiro 80%, Balcão 50%, Call Center 25%, Afiliado 10% do que o banco paga. Migration `20261007170241_fintech_corban_tables_v1` (aplicada em produção 07/10/2026, md5 conferido), contrato `tests/security/fintech-corban-tables-contract.sql` (14/14).
- Próximo passo combinado: a importação de tabelas passar a ler Valor Inicial / Valor Final e a faixa da linha líquida comparar com o valor liberado.

### Bevicred: testar conexão (07/10/2026)
- Adicionado: Configuração > Bevicred, só para o administrador da Smart. O botão "Testar conexão Bevicred" pede o token à Bevicred com o código de parceiro e a chave guardados como segredo na Vercel e mostra só se conectou ou o erro; o token é descartado e nada é lido nem gravado (ADR-0050).

### Mensagem de senha recusada: mínimo 12 (07/10/2026)
- Corrigido: a mensagem de senha inválida (Equipe e acesso ao portal) dizia "8 a 72 caracteres"; o mínimo é 12 desde #94. Agora diz "no mínimo 12 caracteres (até 72)".
- Dado corrigido em produção, com aprovação do dono: o e-mail de login de uma corretora externa estava digitado errado; trocado no Auth (usuário e identidade), mesma conta, vínculo e histórico. Feito direto no banco, não em migration, porque o e-mail é dado pessoal e não vai para o repositório.

### Portal do corretor externo: Meus contratos (06/10/2026)
- **Adicionado:** o portal vira "Meu portal": Previsto, Liberado, Recebido no mês e Propostas aguardando; "Meus contratos" com todos os contratos em que ele é o vendedor, inclusive os digitados pela empresa (marcados assim), com a situação e a parte dele (aguardando cliente/banco, liberado, recebido); botão Ver meu extrato. O detalhe abre também contratos digitados pela empresa. "Propostas enviadas" mostra só as que aguardam ou foram recusadas.
- Migration `20261006223312_seller_contracts_v1` (aplicada em produção) (função de leitura `public.seller_contracts`). Teste de contrato `seller-contracts-contract.sql`.

### Acesso ao portal: senha de 12 e nova tentativa (06/10/2026)
- **Corrigido:** criar acesso de vendedor falhava na 2ª tentativa com erro genérico: a 1ª (senha recusada pelo login) deixava o convite pendente. Agora, se o convite pendente é do mesmo vendedor, a nova tentativa segue e cria o login; se é de outro acesso, a mensagem explica.
- **Alterado:** senha digitada no Corban passa a ter no mínimo 12 caracteres (o mínimo que o login de produção exige; antes a tela aceitava 8 e o login recusava). Dica no campo e mensagem de senha fraca com a regra.

### Meu painel de vendedor (06/10/2026)
- **Adicionado:** quem está ligado a um vendedor e não é só vendedor (gerente, administrador, supervisor, operador) ganha no topo da Visão geral o seletor "Visão geral | Meu painel de vendedor", que abre o painel do vendedor com os números só dele. Sem migration.

### Vendedor ligado a usuário da equipe (06/10/2026)
- **Adicionado:** na ficha do vendedor, "Acesso ao sistema": ligar o vendedor a um usuário que já existe na equipe, de qualquer papel (gerente, administrador, supervisor, vendedor), ou desfazer a ligação. Quando o e-mail do vendedor é de alguém da equipe, a tela sugere ligar em vez de criar outro login. O papel não muda; a produção do vendedor conta como da pessoa (meta). Uma pessoa, um vendedor.
- Migrations `20261006202214_seller_user_link_v1` (aplicada em produção) e `20261006202249_link_manager_sellers_v1` (aplicada; liga GERDEAN e FRANCISCO JUNIOR) (`set_seller_user` aceita qualquer papel ativo e recusa `user_already_linked`). Teste de contrato `seller-user-link-contract.sql`.

### Contas a pagar: parcelas no mesmo mês (06/10/2026)
- **Adicionado:** campo "Intervalo" no lançamento: Todo mês, A cada 15 dias, A cada 7 dias ou A cada X dias; vale para repetir e para parcelar (ex.: 2 vezes a cada 15 dias, 3 vezes a cada 10 dias). "Quantos meses" vira "Quantas vezes". Migration `20261006200923_fin_interval_days_v1`, aplicada em produção (`fin_create_entry` ganha `p_interval_days`, padrão = 1 mês).

### Painel do vendedor (06/10/2026)
- **Adicionado:** a Visão geral do vendedor (perfil de agente ligado a um cadastro de vendedor) vira o painel dele, pensado para o celular (modelo F): meta do mês em anel, quanto vai ganhar (previsto, liberado para o próximo pagamento, recebido no mês), pendências no banco e últimos contratos com a parte dele. Só os números dele; nada da empresa. Agente sem cadastro de vendedor continua com o painel do operador.
- Migration `20261006200125_seller_dashboard_v1` (aplicada em produção) (função de leitura `public.seller_dashboard`). Teste de contrato `seller-dashboard-contract.sql`.

### Dados: folha de pagamento relançada (06/10/2026)
- **Dados:** a "Folha de Pagamento" lançada como 3 parcelas de R$ 477,46 (parcelamento por engano) foi cancelada, com motivo no histórico, e relançada como R$ 1.432,40 por mês em 4 meses (07/10/2026 a 07/01/2027), a pedido do dono. Migration `20261006192830_fix_payroll_entry_v1` (aplicada em produção).

### Contas a pagar: repetir x parcelar (06/10/2026)
- **Corrigido:** o campo "Parcelas" dividia o valor; o dono queria repetir (salário). Agora "Como lançar": Uma vez, Repetir todo mês (mesmo valor) ou Parcelar (dividir o valor), com "Quantos meses" e exemplo na tela. Migration `20261006192321_fin_repeat_entries_v1`, aplicada em produção (`fin_create_entry` ganha `p_repeat`, padrão = parcelar como antes).

### Painel do operador (06/10/2026)
- **Adicionado:** a Visão geral de quem não vê o financeiro vira o painel do operador (modelo C): Na esteira, Parados há 3+ dias, Pendências no banco (com prazo vencido), Pagos no mês; "Precisa de você" (pendência vencida e contratos parados, mais antigos primeiro); esteira por etapa; metas do mês (o vendedor vê só a própria). Sem comissão nem dinheiro da empresa; o que cada um vê segue o escopo do perfil. Sem migration.

### Painel do dono (06/10/2026)
- **Adicionado:** a Visão geral, para quem vê o financeiro, vira o painel do dono (modelos A + D + B + E): período Hoje/7 dias/Mês/Ano comparado com o período equivalente; Produção paga, Comissão prevista, Recebido dos bancos e Fica na empresa; "Precisa da sua atenção" (banco atrasado 30+ dias, divergência, vendedores a pagar, comissão desatualizada, pago sem cálculo, esteira atrasada); produção por dia ou mês; vendedores; cartões por banco (ticket médio, falta receber); esteira agora. Todo número abre os contratos por trás dele. Os outros perfis continuam com a tela atual.
- **Adicionado:** Contratos ganha os filtros "pagos ao cliente entre" e "aguardando comissão do banco" / "comissão divergente".
- Migration `20261006184724_owner_dashboard_v1` (aplicada em produção) (função de leitura `public.owner_dashboard`, só financeiro). Teste de contrato `owner-dashboard-contract.sql` (somas batem com os contratos).

### Documentos padrão e mais de um arquivo por documento (06/10/2026)
- **Adicionado:** tipos "RG ou CNH" e "Extrato de consignação". Lista padrão publicada em todos os bancos/convênios da Smart Promotora sem lista: Contracheque, RG ou CNH, Comprovante de endereço, Extrato bancário, Selfie, Extrato de consignação, Outros, **todos opcionais** (cada dono marca obrigatório por banco em Cadastros > Documentos por banco). Migration `20261006180841_standard_documents_v1` (aplicada em produção).
- **Alterado:** no contrato, cada documento mostra os arquivos já anexados e o botão "Adicionar outro arquivo".

### Dados: recebimento da comissão do contrato 131259 (06/10/2026)
- **Dados:** comissão HOPE do contrato 131259, R$ 1.900,00 à vista, recebida em 11/09/2026 (valor e data informados pelo dono). Registrada pela mesma função do "Registrar recebimento". Migration `20261006163219_receipt_hope_131259_v1` (aplicada em produção).

### Contrato sem repasse fica concluído (06/10/2026)
- **Alterado:** contrato em que o vendedor recebe R$ 0,00 (produção própria, grupo Smart Promotora), já pago ao cliente e com a comissão do banco recebida, aparece como "Concluído · sem repasse" em vez de "liberado, a pagar". Nenhum pagamento de R$ 0,00 é registrado. Filtro "Repasse ao vendedor" ganha "Sem repasse" e "Concluído (pago ou sem repasse)".
- Migration `20261006162112_no_payout_concluded_v1` (aplicada em produção) (só a função `private.contract_credit_state`, estado novo `no_payout`; nenhum dado muda). Simulado na produção: só os 11 contratos de produção própria mudam.

### Repasse: pagar vendedores em lote com QR Code PIX (06/10/2026)
- **Adicionado:** cartão "Pagar vendedores" na tela Repasse (quem pode aprovar pagamentos): lista de quem tem valor a pagar, com o valor exato que o sistema registra, a chave PIX (copiar) ou os dados da TED e o favorecido. QR Code PIX com o valor e PIX copia e cola (BR Code do Banco Central, gerado no Corban, sem integração bancária), navegação Anterior/Próximo e aviso para conferir o nome no banco. Planilha Excel da lista. "Confirmar pagos" registra só os marcados, com data e comprovante opcional, como o Pagar agora.
- **Segurança/dinheiro:** migration `20261006154254_payout_batch_v1` (aplicada em produção): `private.pay_now_amount` (o valor que o Pagar agora pagaria hoje, sem gravar), `public.payout_pay_list` e `public.pay_account_now_checked` (recusa com `amount_changed` se o valor mudou desde a lista). Nunca a própria conta. Teste de contrato `payout-batch-contract.sql`.
- Dependência nova: `qrcode` (MIT).

### Contratos: recalcular comissões em lote (06/10/2026)
- **Adicionado:** na tela Contratos, caixa de seleção em cada linha e barra "Recalcular selecionados" (marcar todos da página, marcar desatualizados). Cada contrato é recalculado pela mesma função do botão Recalcular do contrato; os que não podem (vendedor já recebeu, sem vendedor, sem linha na tabela…) aparecem listados com o motivo, e os outros seguem. Até 300 por vez.
- **Adicionado:** etiqueta "Comissão desatualizada" e filtro "Só comissão desatualizada" (financeiro): o vendedor do contrato ou o grupo dele mudou depois do cálculo.
- Sem migration.

### Cadastro de vendedor não perde os dados no erro (06/10/2026)
- **Corrigido:** quando o banco recusava o cadastro (ex.: favorecido sem CPF/CNPJ), a tela recarregava e apagava tudo. Agora o formulário continua com o que foi digitado e mostra a mensagem logo acima do botão.
- **Alterado:** ao marcar "favorecido", nome e CPF/CNPJ do favorecido e a chave PIX (ou banco, agência e conta, em TED) passam a ser pedidos antes de enviar.

### Repasse: Diário como padrão (06/10/2026)
- **Alterado:** vendedor novo vem com "Recebe o repasse: Diário" (formulário, cadastro sem o campo e padrão da coluna). Na tela Repasse, "Fechar período" já abre em Diário. Migration `20261006135519_seller_daily_payout_default_v1` (aplicada em produção) (só o padrão; nenhum vendedor muda).

### Vendedores: repasse diário (06/10/2026)
- **Dados:** todos os vendedores da Smart Promotora passam a "Recebe o repasse: Diário" (pedido do dono). Só esse campo; extratos, créditos e pagamentos não mudam. Novos vendedores continuam com o padrão Mensal. Migration `20261006135024_smart_sellers_daily_payout_v1` (aplicada em produção).

### NASP – Governo do Acre: Refinanciamento com a comissão do Novo (05/10/2026)
- **Adicionado:** as 4 tabelas Temporário e Comissionado do NASP Gov. Acre ganham a linha Refinanciamento igual à de Novo (6% ou 10% à vista no líquido, mesmo repasse por grupo), numa vigência v2 a partir de 01/01/2026; a v1 fica no histórico. Efetivo (Normal/REFIN/COMPRA) e Prefeitura de Rio Branco já tinham Refinanciamento e não mudam.
- Migration `20261005235551_nasp_acre_refin_lines_v1` (aplicada em produção); teste de contrato `tests/security/nasp-acre-refin-contract.sql`.

### Importação PROSESP: PROPOSTA vira a ADE (05/10/2026)
- **Alterado:** no layout PROSESP (WorkBank), a coluna PROPOSTA passa a ser a ADE e CONTRATO vai para a observação. O relatório de comissão da PROSESP ("Acerto da Produção") identifica o contrato pela PROPOSTA; com a ADE pelo CONTRATO a conferência não casava sozinha.
- **Dados:** migration `20261005224329_prosesp_workbank_proposal_numbers_v1` grava a PROPOSTA como segundo número (identidade) dos 10 contratos PROSESP importados em 05/10/2026. Só acrescenta; nada é alterado ou apagado.

### Importação PROSESP: situação "CR CLIENTE" = Pago (05/10/2026)
- **Alterado:** na importação de contratos, a situação "CR CLIENTE" do relatório WorkBank passa a ser lida como Pago ao cliente (data = OPERAÇÃO). Sem migration.

### Repasse alterado: só o Administrador vê e altera (05/10/2026)
- **Segurança:** o vendedor e o corretor do portal não enxergam mais o valor "pela regra". `proposal_commission_mine` devolve só o valor a pagar; o vendedor não lê mais as linhas de comissão direto da tabela; a "Comissão prevista" do portal soma o valor a pagar (antes somava a regra e mostrava o valor cheio mesmo com repasse reduzido).
- **Alterado:** alterar o repasse do vendedor passa a ser só do Administrador (antes Administrador ou Gerente). Etiqueta "Alterado"/"Repasse alterado", coluna "Vendedor pela regra", "Ganho com alterações de repasse", filtro "Só repasse alterado" e o histórico da alteração aparecem só para o Administrador. Outros perfis do financeiro veem o valor a pagar como o valor do vendedor.
- Migration `20261005204135_payout_override_admin_only_v1` (funções e políticas; nenhum dado alterado). Testes de contrato atualizados.

### Importação de contratos: layout PROSESP (relatório WorkBank) (05/10/2026)
- **Adicionado:** layout "PROSESP (WorkBank)" na importação de contratos. Lê o relatório "Gestão de Créditos" como vem: aceita a linha de título acima do cabeçalho; PRODUTO cortado em 20 caracteres vira o nome da tabela PROSESP; CONTRATO é a ADE; PROPOSTA vai para a observação; OPERAÇÃO (única data do relatório) vale como "Pago ao cliente em"; REPASSE, COMISSÃO, FÍSICO, BANCO, DIGITADOR e AGENTE são ignorados de propósito (vendedor se informa no contrato).
- **Alterado:** a etapa "CONCRETIZADO/CONCRETIZADA" passa a ser lida como Pago em qualquer layout; o cabeçalho pode estar em qualquer uma das 5 primeiras linhas.
- Sem migration. Testes unitários com valores fictícios.

### Importação de contratos: arquivo da NASP direto (.csv) e ficha do cliente (03/10/2026)
- Adicionado: a importação aceita .csv (";" ou ",", UTF-8 ou Windows-1252) além de .xlsx. O layout NASP conhece as colunas do relatório "contratos pagos" da NASP: Operação → tipo, Fase (credito_liberado = Paga), Data da liberação → pago ao cliente em, Qtd parcelas, Valor líquido pago / Valor bruto liberado, Agente → vendedor, Saldo por dentro / Quitação externa → saldo devedor; colunas de valor que não usamos (comissão, mensalidade, IOF, valor final) ficam ignoradas de propósito e listadas na tela.
- Adicionado: a planilha completa a ficha do cliente — dados pessoais (nascimento, sexo, estado civil, naturalidade, mãe, pai, RG, órgão, UF, expedição, WhatsApp), endereço, conta bancária e matrícula (no convênio da tabela). Só preenche o que estiver vazio; endereço só se o cliente não tiver; conta e matrícula só se ainda não existirem. Valor ruim nesses campos vira aviso, nunca recusa o contrato. Contrato já existente não muda, mas a ficha do cliente é completada. O modelo para baixar ganhou essas colunas (opcionais).
- Sem banco novo: nacionalidade, escolaridade, PIS, cônjuge, PEP, analfabeto, cargo, lotação, salário e admissão ainda não têm campo no Corban (proposta separada).

### Tabelas NASP – Prefeitura de Rio Branco (03/10/2026)
- Adicionado (dados): 4 tabelas NASP – Pref. Rio Branco, ativas, digitais, vigência 01/01/2026, cada uma com linhas Novo e Refinanciamento, juros 0%, sem faixa de valor, comissão à vista sobre o líquido: Prefeitura Temporário 4–7 e Prefeitura Comissionado 4–7 (6%), Prefeitura Temporário 8–18 e Prefeitura Comissionado 8–24 (10%). Repasse igual ao das NASP – Gov. Acre (decisão do dono). Migração `20261004004850_nasp_rio_branco_tables_v1` aplicada em produção (md5 conferido, 4 tabelas e 8 linhas conferidas); contrato SQL `nasp-rio-branco-tables-contract.sql` (11 checagens).
- Alterado: na importação de contratos, a coluna Tabela casa primeiro com o nome inteiro, depois com a última parte do nome ("Temporário (4 a 7 meses)" = Gov. Acre; "Prefeitura Temporário (4 a 7 meses)" = Rio Branco), depois com o final do nome.

### Tabelas NASP – Governo do Acre e importação de contratos por planilha (02/10/2026)
- Adicionado (dados): 7 tabelas NASP – Gov. Acre, todas ativas, vigência 01/01/2026, digitais, uma linha por tabela para toda a faixa de prazo, sem faixa de valor: Temporário 4–7 e Comissionado 4–7 (6%), Temporário 8–18, Comissionado 8–24, Normal Efetivo/Pensionista 24–84 (Novo), REFIN – NORMAL 24–84 (Refinanciamento) e COMPRA NORMAL 24–84 (Compra de Dívida), todas 10%. Juros 0% onde a lista diz 0% e vazio onde diz "—". Repasse (decisão do dono): 10% → Balcão 5, Call Center 2,5, Afiliado 1, Corretor 4, Parceiro 4; 6% → Balcão 3, Call Center 1,5, Afiliado 0,6, Corretor 2, Parceiro 2. Migração `20261002122145_nasp_acre_tables_v1` aplicada em produção (md5 conferido, 7 tabelas publicadas conferidas); contrato SQL `nasp-acre-tables-contract.sql` (10 checagens).
- Adicionado: tela Esteira → "Importar planilha" (`/app/propostas/importar`) com o layout NASP. Baixar modelo (colunas, listas de Tipo/Etapa/Tabela e aba com as tabelas do banco em vigor) → Conferir (cada linha contra tabelas, faixa de prazo, equipe e clientes; nada gravado) → Importar (só sem erros). Cliente achado pelo CPF ou criado; mesmo banco + ADE, ou sem ADE o mesmo cliente + tabela + prazo + valor, não duplica. Etapa da planilha aplicada pelo mesmo mover da esteira (Paga exige "Pago ao cliente em"). Coluna faltando não recusa; coluna de valor desconhecida recusa; outras colunas desconhecidas são listadas como ignoradas. Sem vendedor a comissão espera o vendedor no contrato, como no cadastro pela tela.

### Tabela PROSESP – Pref. Rio Branco – Efetivo (01/10/2026)
- Adicionado (dados): tabela publicada com vigência 18/06/2026, digital, uma linha só: Novo, 24 a 36 meses, R$ 300 a R$ 15.000, 7% à vista sobre o líquido. Repasse: Balcão 3,5%, Corretor 4%, Parceiro 4%, Call Center 1,75%, Afiliado 0,7%. Coluna "Mensalidade" da planilha ignorada (decisão do dono). Migração `20261002020947_prosesp_rio_branco_table_v1` (md5 conferido); conferido local: R$ 5.000 líquido = R$ 350,00 de comissão.

### Esteira simples (01/10/2026)
- Adicionado: Kanban com arrastar e soltar (mouse, teclado e celular) para qualquer coluna, inclusive Paga, Recusada e Cancelada (estas mostram os últimos 7 dias). Soltar em Paga pede só a data (hoje já preenchida).
- Adicionado: no modo tabela, cada linha tem a lista de etapas e "Salvar".
- Alterado: a proposta vai de qualquer etapa para qualquer etapa (voltar, reabrir), no contrato, na tabela e no Kanban. Observação e prazo da pendência são opcionais. Todo movimento entra no histórico.
- Segurança: única trava de dinheiro — contrato Pago com comissão recebida do banco ou repasse ao corretor não sai de Paga; tirar de Paga só administrador ou gerente. Migração `free_pipeline_moves_v1` (RPC `move_case_to_stage`; `move_operational_case` continua como atalho por estado). Contrato SQL: 20 checagens.

### Saldo devedor e dados de origem (01/10/2026)
- Adicionado: em Nova proposta, Editar contrato e portal do corretor, quando o tipo não é Novo: "Saldo devedor (R$)", "Banco de origem" e "Nº do contrato de origem" (opcionais). Só registro: a comissão segue Bruto ou Líquido conforme cada linha da tabela (decisão do dono). Editar esses campos entra no histórico e não recalcula a comissão.
- Alterado: a mensagem "Contrato atualizado" diz o que recalcula e o que não.
- Banco: migration `contract_origin_details_v1` (colunas em `proposals_v2`; `create_direct_proposal` e `submit_broker_proposal` ganham `p_details`, com valor padrão, então as chamadas antigas seguem funcionando). Contrato `tests/security/contract-origin-details-contract.sql` (9 checagens). Teste de tela.

### Banco → Tipo de contrato → Tabela (30/09/2026)
- Alterado: Nova proposta, Editar contrato, Simulação e portal do corretor escolhem Banco, depois Tipo de contrato, depois Tabela; cada lista filtra a seguinte e só aparece a vigência em vigor de cada tabela. O mesmo banco por promotoras diferentes aparece como "Bevicred - Daycoval", "Efetivamais - Daycoval" (ADR-0049).
- Corrigido: contrato com tabela que tem Novo e Refinanciamento no mesmo prazo não calculava a comissão ("há mais de uma linha da tabela"). O tipo de contrato agora fica no contrato e o cálculo usa a linha do tipo; editar um contrato sem comissão tenta calcular na hora; recálculo mantém a linha usada.
- Adicionado: em Cadastros > Bancos, "Vendas por promotora" com o IR retido de cada "Promotora - Banco" (em branco = 0%). O IR do banco vale para a produção própria.
- Removido: `src/lib/proposals/table-options.ts` (lista antiga "Banco e tabela").
- Banco: migration `contract_type_and_origin_ir_v1`. Contrato `tests/security/contract-type-origin-ir-contract.sql` (17 checagens). Testes de tela atualizados para os três passos.

### Comprovante opcional no Pagar (29/09/2026)
- Alterado: no "Pagar" da conta de repasse, o comprovante é opcional (pedido do dono: transcrever o ID do PIX dava trabalho). Em branco, o pagamento fica registrado como "Sem comprovante informado", com data e quem pagou. Migration `pay_now_optional_proof_v1` (só a checagem do comprovante em `pay_account_now`).

### Pagar o corretor em um passo (29/09/2026)
- Adicionado: na conta de repasse de cada pessoa, "Pagar" ao lado do saldo: data, comprovante (ID do PIX) e o botão "Pagar R$ X". O saldo é baixado, o pagamento fica no extrato e entra no financeiro da empresa. Sem fechar período e sem aprovação de outra pessoa (ADR-0048); fica registrado quem pagou, quando e o comprovante. Ninguém paga a própria conta.
- Alterado: "Lançamento avulso" virou "Outros lançamentos: vale, bônus, desconto", recolhido e com o aviso "não é pagamento" (o dono quase lançou um vale achando que pagava).
- Banco: migration `pay_account_now_v1`; o cálculo do extrato de uma conta saiu de `close_payout_period` para `private.close_payout_account`, usado pelos dois (mesma regra). Contrato `tests/security/pay-account-now-contract.sql` (16 checagens); contratos antigos de repasse seguem passando. Teste de tela.

### Registrar recebimento no contrato (29/09/2026)
- Adicionado: no quadro de comissão do contrato, "Registrar recebimento" (tipo à vista, diferido ou estorno; valor; data em que caiu; parcela opcional do diferido; observação), para quem aprova o financeiro. Para banco sem relatório ou dinheiro visto na conta antes do relatório.
- Regra: entra pelo mesmo caminho do relatório do banco, como um "Lançamento manual" de uma linha da fonte pagadora do contrato (promotora parceira quando a produção é via promotora, senão o banco): compara com o esperado do cálculo (sem tolerância; diferença vai como divergente para a Conciliação), recusa repetido (mesmo tipo e parcela), estorno acima do recebido fica divergente (como no arquivo), lança no financeiro da empresa e libera o crédito do vendedor como qualquer recebimento. Tudo ou nada.
- Banco: migration `manual_commission_receipt_v1` (`register_manual_receipt`, security invoker: cada etapa confere as permissões de quem registra). Contrato `tests/security/manual-commission-receipt-contract.sql` (17 checagens). Teste de tela.

### Senha: mínimo 8 e troca no primeiro acesso opcional (29/09/2026)
- Alterado: senha digitada no Corban aceita de 8 a 72 caracteres (era 10), decisão do dono; a mesma regra em Equipe, acesso do corretor ao portal e "Criar senha" (`PASSWORD_MIN` em `src/lib/team.ts`). O Supabase pode ter regras próprias; a recusa diz o motivo.
- Alterado: "Pedir nova senha no primeiro acesso" (e "no próximo acesso", ao redefinir) vem desmarcado; o dono marca quando quiser. O gerente criado em produção ficou preso nesse passo porque a senha escolhida por ele esbarrava nas regras do Supabase.

### Motivo da senha recusada (29/09/2026)
- Corrigido: ao criar acesso ou redefinir senha, quando o serviço de login recusava a senha (regras de senha do projeto no Supabase: tamanho, tipos de caractere, senha vazada), a tela dizia só "o serviço de login recusou". Agora diz o motivo e dá exemplo. Vale também para o acesso do corretor ao portal e para a pessoa escolhendo a própria senha no primeiro acesso.
- Teste de tela com as regras de senha forte ligadas no Supabase local (`E2E_STRONG_PASSWORDS=1`).

### Acesso criado com senha (29/09/2026)
- Alterado: em Equipe, "Criar acesso" com e-mail, perfil e senha (com "Mostrar senha"); a pessoa entra na hora, sem e-mail. "Pedir nova senha no primeiro acesso" vem ligado: no primeiro login nada abre antes de ela escolher a própria senha. Cada membro tem "Redefinir senha" (só para quem é só desta empresa; nunca a própria, nunca papel acima do seu).
- Alterado: na ficha do vendedor, "Acesso ao portal" também cria o acesso do corretor com e-mail e senha.
- Removido: convite por e-mail e "Reenviar" na tela Equipe (convites pendentes antigos continuam listados, com Cancelar; criar o acesso com o mesmo e-mail troca o convite). "Esqueci minha senha" continua.
- Banco: migration `member_access_with_password_v1` (ADR-0047). Contrato `tests/security/member-access-password-contract.sql` (19 checagens). Testes de tela: criar acesso, primeiro acesso com troca de senha, redefinir senha, recusas, e acesso do corretor ao portal.

### Link do convite e do "Esqueci minha senha" (29/09/2026)
- Corrigido: quem clicava no link do convite via "Este link é inválido ou expirou". O Supabase manda a sessão depois do `#` do link e o cliente do navegador (fluxo PKCE) ignora esse formato; a página "Criar senha" agora lê a sessão do link, valida no Supabase e limpa o endereço. Link já usado mostra "Este link já foi usado" (cada link vale uma vez).
- Corrigido: depois de criar a senha, uma segunda navegação simultânea podia mostrar "Acesso ainda não liberado" mesmo com o convite aceito; agora é uma navegação só, e a tela de acesso pendente manda para o app quem já está ativo.
- Alterado: "Esqueci minha senha" manda link que funciona em qualquer aparelho (pedido no computador, aberto no celular). "Reenviar convite" para quem já validou o e-mail manda o link de criar senha (antes não enviava nada).
- Testes de tela: convite de ponta a ponta (convidar, e-mail, criar senha, entrar na empresa, link repetido) e "Esqueci minha senha" em outro navegador (precisam de `E2E_MAIL_API`).

### Remoção de sobras (29/09/2026)
- Removido: telas `/app/operacional` (atalhos antigos, sem link), `/app/documentos` (o envio fica na ficha do cliente e no checklist da proposta) e `/app/leads` (só redirecionava para Vendas). A ação de envio de documento foi para `src/app/app/clientes/documentActions.ts` e sempre volta à ficha.
- Removido: coluna `commission_groups.calculation_basis` ("percentual da comissão recebida"), com a trava que forçava o valor. Desde 26/09 os valores de repasse são pontos da operação e nada lia a coluna. Backup em `backup_c6.commission_groups_calculation_basis` (fora da API), apagado só com aprovação do dono. `save_seller_group` igual, sem a coluna. Contrato `tests/security/drop-group-calculation-basis-contract.sql` (7 checagens).
- Mantido: Relatórios (decisão do dono, 29/09/2026).

### Data de início da vigência (29/09/2026)
- Adicionado: na tabela em rascunho, campo "Início da vigência" ao lado de Publicar. Vazio = começa hoje, como antes. A vigência anterior termina nessa data; data anterior a uma vigência já publicada é recusada. Nova função `publish_product_table_version(uuid, date)` (meia-noite de Brasília, até um ano à frente) que grava a data e chama a publicação de sempre na mesma chamada. Contrato `tests/security/table-version-start-date-contract.sql` (14 checagens) e teste de tela.
- Corrigido (testes): os contratos `group-value-rounding` e `prosesp-tables-publish` criam os próprios dados e passam num banco recém-reconstruído.

### Tabelas PROSESP publicadas (29/09/2026)
- Alterado: as 3 tabelas PROSESP do Governo do Acre (Comissionado, Efetivo, Temporário), importadas em 21/09 como rascunho sem data, são publicadas com vigência a partir de 01/01/2026 (meia-noite de Brasília), decisão do dono. Migration `prosesp_tables_publish_v1` segue as regras de `publish_product_table_version` (só rascunho, só com linhas, flag governada) e recusa estado inesperado. Contrato `tests/security/prosesp-tables-publish-contract.sql` (7 checagens).

### Documento na ficha e no checklist (28/09/2026)
- Corrigido: a única tela de envio de documento (Documentos) não estava em nenhum menu. Agora o documento é enviado direto na ficha do cliente (quadro Documentos) e em cada item do checklist da proposta ("Enviar arquivo" já liga o arquivo ao item).
- Alterado: situação dos itens do checklist em português (Falta, Anexado, falta validar, Validado...); a lista de documentos da ficha mostra tipo, versão e nome do arquivo.

### Repasse sem sobra de arredondamento (28/09/2026)
- Corrigido: 8 valores de repasse (PROSESP, Governo do Acre, Efetivo 24 e 36 meses, Corretor e Parceiro) estavam como 3,00000001 em vez de 3. Vieram da conversão de 26/09 (fatia 3/7 guardada com 6 casas: 7 × 42,857143 ÷ 100). A migration `group_value_rounding_v1` arredonda só valores convertidos a menos de 0,000001 de um número com 4 casas; versões publicadas continuam imutáveis (a guarda recusa). Tabelas estavam em rascunho, nada foi calculado com o valor errado. Contrato `tests/security/group-value-rounding-contract.sql` (9 checagens).

### Esteira no celular (28/09/2026)
- Alterado: no celular a Esteira mostra um cartão por proposta (cliente, etapa, banco e ADE, valor, vendedor, dias na etapa, alerta), sem a tabela larga que rolava para o lado. No computador nada muda.

### Corban instalável no celular (28/09/2026)
- Adicionado: manifesto de app e ícones. No celular, "Adicionar à tela inicial" (Chrome/Android) ou Compartilhar > "Adicionar à Tela de Início" (Safari/iPhone) instala o Corban com ícone próprio, abrindo em tela cheia na tela Hoje. Sem loja de aplicativos.

### Menu no celular (28/09/2026)
- Corrigido: no celular a barra de baixo tinha só Hoje, Dashboard, Clientes e Esteira; Vendas, Contratos, Metas, Financeiro e Sair não tinham como ser abertos. Agora a barra tem Hoje, Clientes, Vendas, Esteira e "Mais", que abre o menu completo com as subpáginas e o Sair.

### Revisão das telas do fluxo diário (28/09/2026)
- Corrigido: tabela de Contratos cabe na tela (coluna Margem cortada); proposta sem vendedor explica como corrigir a comissão; "Números no banco" sem código técnico; origem "legacy:2tech" aparece como "Base antiga (2tech)"; eventos da Equipe traduzidos; campo de meta sem valor de exemplo que parecia salvo; retorno na Hoje mostra o ano quando não é o ano atual.

### Documentos por banco (27/09/2026)
- Adicionado: Cadastros > Documentos por banco. Marque o que cada banco pede (obrigatório ou opcional) para um ou vários convênios dele de uma vez; cada salvar publica uma nova versão por banco+convênio. Na proposta, "Preparar checklist" traz essa lista.

### Tipos de documento padrão (27/09/2026)
- Adicionado: 16 tipos de documento de correspondente consignado (RG, CNH, comprovante de residência, contracheque, extrato do benefício, HISCON, saldo devedor, CCB...). Produção não tinha nenhum, então nenhum documento podia ser guardado.
- Corrigido: Documentos carregava todos os clientes numa lista; agora o campo Cliente é a busca por nome ou CPF.

### CRM de vendas (27/09/2026)
- Adicionado: menu Vendas com quadro por etapa (Novo, Em contato, Negociando, Proposta, Ganho, Perdido), arrastar para mudar a etapa, busca por nome, telefone ou CPF (CPF por POST).
- Adicionado: campanhas com planilha (XLSX/XLS/CSV lida no navegador), escolha das colunas, cliente existente ligado pelo CPF ou telefone sem duplicar, distribuição por fila, supervisor ou rodízio, resultado por vendedor.
- Adicionado: ficha do lead com colunas da planilha, histórico, anotação, próximo contato (aparece na Hoje), WhatsApp e Simular (cadastra o cliente pelo CPF e abre a simulação).
- Alterado: Proposta e Ganho seguem a proposta do cliente (criada, paga; recusada ou cancelada volta para Negociando). A fila de leads sem dono não é mais listada para o vendedor: ele pega o próximo.
- Removido: a lista antiga de leads (`/app/leads` leva ao quadro).
- Adicionado (validação): botão Subir planilha na campanha e na lista de campanhas, arrastar o arquivo, e modelo em Excel (aba Leads com as colunas e aba Instruções).

### Ficha completa do cliente (25/09/2026)
- Dados pessoais (pais, RG, sexo, estado civil, naturalidade, WhatsApp, nascimento), dados bancários e várias matrículas por cliente com margem e acesso; senha da matrícula criptografada no cofre, mostrada só a quem pode editar e com registro de cada visualização.

### F7 — Portal do corretor (24/09/2026)
- Corretor com papel próprio envia propostas pelo portal (menu reduzido, pensado para celular); elas aguardam validação de outra pessoa antes de entrar na esteira e de ter comissão calculada.
- Recusa sempre com motivo, visível ao corretor; documentos anexados ficam no bucket privado, só para o corretor e a empresa.
- CPF que já é cliente: a proposta entra sem mostrar nem alterar o cadastro existente; a fila interna avisa "cliente já existe, carteira de X".
- Convite de portal a partir do cadastro do vendedor, já com o papel Corretor; alerta de validação pendente na tela Hoje.

### Visibilidade de comissão, limpeza de documentos e testes (24/09/2026)
- Vendedor vê só a própria parte da comissão, só nas próprias propostas (ADR-0031); coluna antiga `expected_commission_amount` removida.
- 65 documentos da era ChatGPT removidos (ADR-0030); deploy consolidado em `docs/DEPLOY.md`.
- 17 contratos SQL antigos removidos; banco local com as mesmas permissões e dados de referência de produção; correção de permissão da tela Equipe (supervisor, filial, escopo, papel personalizado).

### F6 — Repasse e conta corrente (24/09/2026)
- Conta corrente por pessoa com lançamentos imutáveis: comissão conciliada, estorno proporcional, vale/desconto parcelados, bônus, ajuste e pagamento.
- Fechamento periódico com limite de 30% de desconto do saldo negativo, ou conta interna com saque; aprovação sempre por outra pessoa; pagamento marcado com comprovante.
- Correção: vendedor sem login é o originador da própria venda e não herda a hierarquia de quem digitou.

### F5 — Recebimento e conciliação (24/09/2026)
- Importação de relatórios de comissão (à vista, diferido, estorno) por banco ou promotora, com modelo de colunas salvo.
- Conferência linha a linha contra a comissão congelada (tolerância zero), vínculo manual por ADE, ignorar com motivo, confirmação com lançamento imutável.
- Conciliação por contrato, aceite de divergência com motivo, recebido no cartão da proposta, alertas financeiros no Hoje.

### F5 passo 0 — Limpeza de modelos antigos (24/09/2026)
- Removidos (aprovação do dono): modelo de rede/canais, snapshots de rota, sub-regras e supervisões, políticas de repasse por componente, `profiles`, pipeline de importação antigo, eventos/evidências/casos financeiros antigos e hub de integrações, com suas telas e testes.

### F1 — Design system, casca, papéis (24/09/2026)
- Tokens, IBM Plex, componentes base, ponte de paleta: app inteiro claro e na cor da marca.
- Casca por jornada, navegação mobile, busca Ctrl+K, tela Hoje.
- Papéis e permissões por empresa (em produção); alcance dos dados e módulos por plano (prontos, aguardando produção).

### F0 — Saneamento (24/09/2026)
- Mapa real da operação v2 e ADR-0027 (reset de produto).
- Manifesto md5 + script verificado para as 21 migrations que existem só em produção.
- Playwright (desktop + mobile) com testes de rotas públicas.
- Seed guardado da empresa fictícia de teste.
- LF forçado para scripts shell; saídas locais do graphify e do Playwright ignoradas.

### Adicionado — 26/09/2026 (Commercial Model V3)

- Migration preparada `20261002_commercial_model_v3_foundation_v1` (aditiva; não aplicada): `contract_types`, `national_agreement_templates` (27 governos/DF + 26 prefeituras de capitais), catálogo do tenant (`organization_banks/providers/agreements`, `commission_groups`), rota V3, `commercial_conditions` + comissão/participações por grupo, `save_commercial_condition`, `create_simulation_for_condition`.
- Política de repasse (`payout_policies/versions/items`, versões imutáveis, base bruta/líquida, override rastreável) e Origem da Produção Própria/Terceiro (doc V3 §19.3/§20), na mesma migration ainda não aplicada.
- `/app/comercial`, importação CSV/XLSX com uma coluna por grupo de comissão e prévia sem gravar, simulação por condição, configuração V3, testes unitários e harness SQL rollback-only.

### Segurança — 26/09/2026

- Corrigido teto de comissão: era a SOMA dos grupos; agora é POR GRUPO (grupos são vendedores alternativos, como no exemplo do doc V3).
- Unicidade de nomes por `lower(btrim(name))` (espaços não burlam duplicidade); condições congeladas após publicar; comissão e participações só supervisor+; sem Float.
- Teste de arquitetura `worker-hardening` alinhado com os importadores reais do admin client (deriva pré-existente, módulos server-side).
### Segurança — 18/09/2026

- Preparada, mas deliberadamente não aplicada, a migration de policies legadas → membership. O gate A/B exige identidades autenticadas reais em ambiente controlado.
- Confirmado banco vazio: 0 auth users, 0 organizations e 0 memberships; nenhum dado artificial foi inserido no projeto principal.

- Adicionado e aplicado `organization_memberships_v2` como fundação tenant V2 aditiva, preservando o legado.
- `organization_memberships` usa RLS e leitura autenticada apenas do próprio membership ativo; mutações não são concedidas ao papel `authenticated`.
- Helper V2 `is_active_organization_member` usa SECURITY INVOKER.
- Aplicada e versionada `optimize_membership_rls_auth_initplan` após advisor do Supabase apontar reavaliação de `auth.uid()` por linha.
- Advisor pós-correção mantém apenas alerta do helper legado `get_user_organization_id()`; não foi removido ainda para não quebrar policies legadas.

### Performance — 18/09/2026

- Aplicada e versionada migration aditiva com índices para FKs legadas de contracts/import_jobs/profiles. O advisor deixou de reportar FKs sem índice; avisos de índices ainda não usados são esperados em banco vazio.

### Documentação — 18/09/2026

- Baseline vivo do Supabase, plano Tenant/Auth/Membership V2 e contrato de teste de isolamento adicionados.


### Adicionado

- `docs/NEXT-VERSION-NOTES.md` — notas de breaking changes do Next.js 16.3.4, com base na documentação local (`node_modules/next/dist/docs/`).
- `.ai/BRIEFING-RETOMADA.md` — briefing para retomada entre sessões de IA.

### Alterado

- Estrutura de pastas consolidada em `src/app/` — removida pasta `app/` da raiz (boilerplate do `create-next-app`); movidos `globals.css` e `favicon.ico` para `src/app/`. Resolve ADR-0009.
- `tsconfig.json` corrigido: alias `@/*` agora aponta para `./src/*` (antes apontava para `./*`).

### Corrigido

- Import quebrado `./globals.css` em `src/app/layout.tsx` — o arquivo CSS estava em `app/` da raiz; agora está em `src/app/`.

---

## [0.1.1] — 2026-09-11 — Fundação de documentação para IAs

### Adicionado

- `CORBAN-ENTERPRISE-MEMORIA-MASTER-v1.1.md` — fonte de verdade conceitual revisada
- `CORBAN-CURRENT-STATE.md` — estado real do repositório
- `/.ai/RULES.md` — regras operacionais para IAs
- `/.ai/MASTER-CONTEXT.md` — contexto mínimo para IAs
- `/.ai/DECISIONS.md` — registro de decisões arquiteturais (10 ADRs aceitas + 7 pendentes)
- `/.ai/CHANGELOG.md` — este arquivo

### Alterado

- Nome do arquivo de estado: `AI-FACTORY-CURRENT-STATE.md` → `CORBAN-CURRENT-STATE.md`
- Estrutura de pastas consolidada em `src/app/` (ADR-0009) — execução pendente

### Corrigido

- Unicidade de CPF agora é parcial (`WHERE deleted_at IS NULL`) — ADR-0005

### Segurança

- Nenhuma alteração

---

## [0.1.0] — 2026-09-11 — Documento master inicial (v1.0)

### Adicionado

- `CORBAN-ENTERPRISE-MEMORIA-MASTER.md` v1.0 — visão inicial do produto
- Definição de multi-tenant
- Definição de RBAC inicial
- Roadmap com 14 fases
- Regra de Ouro (10 perguntas)

---

## [0.0.1] — 2026-09-09 — Setup inicial do repositório

### Adicionado

- `create-next-app` com Next.js 16.3.4
- TypeScript + Tailwind CSS 4
- Supabase instalado (`@supabase/ssr`, `supabase-js`)
- Estrutura inicial de auth (`middleware.ts`, `server.ts`)
- Página de login em `src/app/login/page.tsx`
- `PROJECT_CONTEXT.md` (desatualizado — será substituído)
- `AGENTS.md` (apenas aviso do Next 16)
- `CLAUDE.md` (aponta para `AGENTS.md`)
- Commit inicial no GitHub

---

# FIM

## 18/09/2026 — Vertical Slice V0 adversarial hardening
- Fixed invalid PL/pgSQL delimiters discovered during integrated review.
- Added FK-path indexes across Catalog, Proposal, Document Vault and Pipeline.
- Enforced same-customer PIX/account integrity and one primary account/PIX per customer.
- Made customer timeline and operational events append-oriented for privileged maintenance paths.
- Bound Proposal to Simulation customer/table snapshot; Proposal requires published table version and freezes commercial evidence after draft.
- Made customer document evidence immutable by version.
- Added linked-evidence validation, privileged waiver guard and transactional documents-ready digitization gate.
- Separated platform administrator authority from tenant admin; tenant provisioning is audited and platform-only.
- No staged vertical-slice migration was applied to the live database.


## 18/09/2026 — Autonomous Vertical Slice execution
- Reconciled `CORBAN-CURRENT-STATE.md` with V2 code/live evidence.
- Added `/app/simulacoes` with tenant-scoped customer + published-table simulation creation.
- Added proposal detail page with commercial snapshot, checklist readiness and operational state.
- Added `/app/documentos` read-only private-vault view; upload intentionally remains blocked until Storage RLS is live.
- Expanded `/app/operacao` to show digitization queue and operational cases.
- Added server-side CPF checksum validation and retained masked CPF list display.
- Prepared, but DID NOT APPLY live, `20260918_vertical_slice_domain_workflow_v0.sql`: one proposal per simulation, selected simulation immutability, proposal state graph, atomic simulation→proposal, checklist snapshot preparation, transactional send-to-digitization.
- Prepared, but DID NOT APPLY live, `20260918_document_storage_rls_v0.sql`: private 15 MiB document bucket, tenant/customer path isolation, authenticated SELECT/INSERT only, no evidence overwrite/delete.
- Added post-apply SQL contract `tests/security/vertical-slice-workflow-contract.sql`.
- Removed the earlier non-atomic UI path for simulation→proposal; current Preview fails closed until the transactional RPC is deployed.
- Vercel build confirmed success through commit `3718b230`.
- Live read-only inventory confirmed catalog/domain data is empty (0 banks/routes/tables/published versions/document types/stages/clients/simulations/proposals); no seed/data mutation was performed.
- Supabase advisors rechecked: 0 security ERROR; existing leaked-password WARN; platform service-role-only INFO; performance unused-index INFO expected on fresh/empty database.


## 18/09/2026 — Workflow/Storage live + document flow
- Applied authorized live migrations `vertical_slice_domain_workflow_v0` and `document_storage_rls_v0`.
- Executed `vertical-slice-workflow-contract.sql` successfully.
- Adversarial review caught checklist fail-open; committed/applied `vertical_slice_workflow_fail_closed_patch` so no published template or zero checklist items can mark a proposal ready.
- Connected Simulation→Proposal to atomic live RPC.
- Connected Proposal→prepare checklist and Proposal→digitization to live transactional RPCs.
- Implemented private document upload with tenant/customer path, MIME/size validation, SHA-256 duplicate detection and version metadata.
- Implemented proposal evidence linking and supervisor+ validation in application.
- Added app error boundary.
- Prepared (not applied) Operational State Machine and RBAC hardening migrations + post-apply contracts.
- Vercel build SUCCESS confirmed through `c9136e5f`.


## 18/09/2026 — Operational state machine + RBAC live
- Applied authorized `operational_state_machine_v0` and `rbac_hardening_v0`.
- Both post-apply SQL contracts passed.
- Supabase advisor identified callable SECURITY DEFINER role helper; applied corrective `rbac_helper_exposure_patch`, removing direct authenticated/anon EXECUTE while preserving RLS use.
- Connected Mesa UI to transactional operational transitions.
- Manual PAID remains prohibited; financial truth is not inferred from operational clicks.
- Added tenant readiness diagnostics at `/app/configuracao`.
- Confirmed live data gate: no banks/tables/checklists/stages/simulations/proposals exist, so no truthful E2E can be fabricated.

### Adicionado — 18/09/2026 (execução LONG-RUN, blocos A–G)
- Migrations espelho (já live) do contrato de integração: catálogo de adapters, bindings, execution ledger, guards de segredo/contrato, mapeamentos canônicos, imutabilidade de raw rows e `dedupe_financial_evidence_insert_policy`.
- Adapter `2tech/busca_contrato_file` (`src/lib/imports/twotech.ts`), contrato canônico (`canonical.ts`) e motor de conflitos (`conflicts.ts`).
- Runner de testes unitários sem novas dependências (`npm run test:unit`, 31 testes) e contratos SQL `integration-contract-v1-contract.sql` e `financial-reversal-paths-contract.sql`.
- Tela de lote: linhagem (adapter/contrato/schema), conflitos entre lotes/fontes do mesmo tenant e evidência de origem por linha.

### Segurança — 18/09/2026 (execução LONG-RUN)
- Comissão e financeiro ocultos para papéis abaixo de supervisor no lote, dashboard, proposta e `/app/financeiro` (gate no servidor sobre RLS).
- PREPARADAS, NÃO APLICADAS: `20260919_financial_reversal_paths_v1`, `20260919_revoke_excess_table_privileges_v1`, `20260919_import_batch_adapter_lineage_v1`.

### Corrigido — 18/09/2026
- Tipagem de `exceljs` (`Buffer`) em `xlsx.ts`; `package-lock.json` sincronizado com `exceljs` já declarado no `package.json`.

### Adicionado — 19/09/2026 (LONG-RUN parte 2)
- Pipeline genérico `prepareImport` (`src/lib/imports/pipeline.ts`) com erros explícitos; a action de ingestão o utiliza e rejeita mesmo arquivo já importado em outra fonte.
- Calculadora exata de comissão esperada (`src/lib/commission`), validada contra `numeric` do Postgres; política RBAC central `atLeast()` (`src/lib/rbac.ts`).
- Harnesses SQL rollback-only: `financial-reversal-behavior-rollback.sql` (57 checagens) e `reconciliation-cases-hardening-rollback.sql` (10).
- Auditoria `docs/audits/AUDIT-2026-09-19-TENANT-RESOLUTION-AND-LIVE-BLOCKERS.md`.

### Corrigido — 19/09/2026
- `parseHtmlTable` falhava com tabelas de menos de 3 colunas; matcher TS agora compara instituição sem diferenciar caixa (como o SQL).
- Modelo de reversão (partial reversals) e lock de concorrência reescritos (migration preparada).

### Segurança — 19/09/2026
- PREPARADAS, NÃO APLICADAS: `20260919_restore_rbac_helper_execute_v1`, `20260919_fix_digest_search_path_v1`, `20260919_reconciliation_cases_write_hardening_v1`, `20260919_financial_reversal_paths_v1` (reescrita), `20260919_import_batch_adapter_lineage_v1` (reescrita).
- JÁ APLICADA externamente (ChatGPT): revogação de TRUNCATE/REFERENCES/TRIGGER (`20260919_revoke_excess_table_privileges_v1`).

### Adicionado — 19/09/2026 (LONG-RUN parte 3)
- `/app/financeiro`: lista de casos com filtros e `/app/financeiro/casos/[id]` com ledger ORIGINAL → REVERSÕES → SALDO LÍQUIDO, evidência/fonte/referência, reversão parcial/total via RPC e resolução humana (só status + justificativa; resolved_by/at do banco). Valores como texto decimal (sem float).
- `src/lib/finance/ledger.ts`, `prepareImport` com detecção de formato por conteúdo, `conflict-persist.ts`, vetores de comissão (60 aleatórios vs Postgres, 0 divergências).
- Harnesses SQL rollback-only: E2E financeiro (44), tenant A/B adversarial (19), conflitos (24), helper+lineage (32).
- Auditorias `docs/audits/AUDIT-2026-09-19-SECURITY-DEFINER.md` e `AUDIT-2026-09-19-E2E-LIVE-BLOCKERS.md`.

### Segurança — 19/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260919_rbac_helper_security_invoker_v1`, `20260919_import_batch_adapter_lineage_v1` (reescrita: schema private), `20260919_financial_read_rbac_v1`, `20260919_fix_import_matching_uuid_aggregate_v1`, `20260919_import_apply_rls_v1`, `20260919_import_identity_case_normalization_v1`, `20260919_import_conflicts_v1`.
LIVE (aplicadas pelo ChatGPT): `revoke_excess_table_privileges_v1`, `restore_rbac_helper_execute_v1`, `fix_digest_search_path_v1`, `financial_reversal_paths_v1`, `reconciliation_cases_write_hardening_v1`.

### Corrigido — 19/09/2026
- Ingestão rejeita mesmo arquivo já importado em outra fonte; extensão do arquivo não decide mais o parser (conteúdo decide).

### Adicionado — 20/09/2026 (closure wave)
- `/organizacao` (seleção explícita de organização), `resolveActiveMembership`/`scopeToOrganization`, `/app/leads`, executor de integrações outbound com adapter fake, harnesses SQL rollback-only (E2E financeiro agora com colunas/multi-org, leads 29, resolução 17).
- Auditoria `docs/audits/AUDIT-2026-09-20-CLOSURE-WAVE.md`.

### Segurança — 20/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260920_column_security_and_tenant_derivation_v1`, `20260920_reconciliation_resolution_immutability_v1`, `20260920_leads_v1` (+ `20260919_import_conflicts_v1` ainda pendente).
Achados: leitura por agent de colunas econômicas; role NULL contornando `not in` nos readers privados (corrigido antes de aplicar); nota/autor/data de resolução reescritos com status inalterado; refresh órfão de caso resolvido; 9 funções com `limit 1` de membership.

### Adicionado — 21/09/2026 (operational integration wave)
- Executor outbound reescrito sobre `RunRepository` (Supabase + gêmeo em memória), contrato de provider com `CapabilityManifest`, gate de evidência, redactor, logger whitelist, provider fake roteirizado (11 comportamentos), registro de homologação, `/app/integracoes`.
- Harnesses: `integration-runs-rollback.sql` (111), `operational-e2e-rollback.sql` (Lead→…→Reconciliation com todas as roles).
- Auditoria `docs/audits/AUDIT-2026-09-21-OPERATIONAL-INTEGRATION-WAVE.md`; contrato de homologação `docs/integrations/2TECH-BUSCACONTRATO-HOMOLOGATION.md`.

### Segurança — 21/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260921_integration_run_state_machine_v1`, `20260921_operational_pipeline_write_hardening_v1`.
Achados: esteira gravável por qualquer membro (forjar histórico / caso `paid`); ledger de integração sem máquina de estados; payload bruto de provider legível por todo membro; segredo persistível em metadata/artefato/erro.

### Adicionado — 22/09/2026 (worker + scheduler + governed retry/cancel)
- `src/lib/integrations/{worker,worker.server,metrics}.ts`, rota `POST /api/integrations/dispatch` (Bearer, desabilitada sem segredo), ações de servidor `retryRun` / `cancelRun` / `reexecuteRun`, UI `/app/integracoes` com Nova tentativa / Cancelar / Nova execução, RunRepository com `enqueue` / `listDispatchable` / `reexecute`.
- Harness `tests/security/worker-governance-rollback.sql`; testes unitários `worker.test.ts` (21).
- Auditoria `docs/audits/AUDIT-2026-09-22-WORKER-GOVERNANCE-WAVE.md`; deploy do worker em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Segurança — 22/09/2026 (PREPARADA, NÃO APLICADA)
`20260922_worker_governance_v1`: corrige `transition_operational_case` (regressão do hardening LIVE), governa escrita de `proposals_v2` e `customer_timeline_events`, adiciona enqueue/dispatch/reexecução.

### Adicionado — 23/09/2026 (regressão LIVE + prova do worker + prontidão de scheduler)
- Dispatch como função pura (`handleDispatchRequest`), guard do fake por allow-list, despacho escopado por adapter, orçamento de tempo do ciclo, histórico de tentativas, erros classificados na UI de operação e de integrações, linhagem visual (execução original / nova execução / motivo).
- Testes: `worker-hardening.test.ts` (arquitetura, dispatch auth, matriz do guard, backpressure/starvation, cancel vs fencing, histórico, repositório real sobre ponte RPC, contrato RPC×SQL).
- SQL: harnesses rodados contra o estado LIVE sem preludes; novos `worker-dispatch-hardening-rollback.sql` e `proposal-paid-evidence-rollback.sql`.
- Docs: `docs/audits/AUDIT-2026-09-23-LIVE-REGRESSION-AND-CLOSURE.md`, `docs/PILOT-GAP-ANALYSIS.md`, seção de scheduler em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Segurança — 23/09/2026 (PREPARADAS, NÃO APLICADAS)
`20260923_worker_dispatch_hardening_v1`, `20260924_confirm_paid_replay_v1`. Achados: starvation de dispatch por adapters irrecuperáveis; histórico de tentativas apagado no retry; mensagem de falha "secreta" travava o run; replay de PAID não idempotente.

### Adicionado - 24/09/2026 (onda de prontidao para piloto)
- Equipe (`/app/equipe`): convidar, reenviar/cancelar convite, alterar perfil, desativar/reativar acesso, trilha de auditoria. Fluxo de convite completo: `/auth/definir-senha`, `/auth/confirm`, aceite no `/access-pending` e `/organizacao`.
- Menu por perfil, dashboard piloto (leads, integracoes com atencao, conciliacoes pendentes, estados `indisponivel`), politica central `canViewCommission`, rotulo `LOCAL / TESTE`, painel de prontidao do worker, `GET /api/health`.
- Testes: `team-access-rollback.sql` (131), `pilot-e2e-rollback.sql` (45), unit 171. Runbook de ativacao e modos de falha do worker/scheduler em `docs/integrations/WORKER-DEPLOYMENT.md`.

### Seguranca - 24/09/2026 (PREPARADA, NAO APLICADA)
`20260925_team_access_lifecycle_v1`. Achado: nao havia caminho governado para gerir equipe e o e-mail de convite nao tinha handler no app.

### Adicionado - 24/09/2026 (fechamento do piloto, onda 2)
- Recuperacao de senha (`/login/recuperar`), historico de tentativas por execucao, painel "Precisa da sua atencao", rotulos da esteira, cache do health, dashboard sem consultas fora do perfil, simulacao via RPC (com fallback temporario).
- Runbooks: `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md`; cadencia do worker em `docs/integrations/WORKER-DEPLOYMENT.md`.
- Testes: unit 189, `simulation-governance-rollback.sql`, `pilot-e2e-v2-rollback.sql` (39), `membership-policy-merge-rollback.sql` (12); regressao LIVE: equipe 83, paid replay 15.

### Seguranca - 24/09/2026 (PREPARADAS, NAO APLICADAS)
`20260926_simulation_governance_v1` (simulacoes forjaveis com comissao arbitraria) e `20260927_membership_select_policy_merge_v1` (advisor WARN de performance).

### Adicionado - 25/09/2026 (fechamento do piloto, onda 3: 1 operador real)
- Feedback humano por codigos, upload com verificacao de bytes, busca, menu por perfil, dashboard do operador, rotulos de proposta/simulacao, botoes anti duplo clique, validacao de CPF.
- Worker: sweep de runs orfaos antes de listar. Documentos: `docs/pilot/*` (checklist, setup do Owner, guias do operador e do supervisor), auditoria da onda 3.
- Testes: unit 211; `revoked-actor-dispatch-rollback.sql` (6 bug / 22 corrigido); chain E2E LIVE 35.

### Seguranca - 25/09/2026 (PREPARADA, NAO APLICADA)
`20260928_revoked_actor_dispatch_v1`: starvation do dispatch por runs de ator revogado CONFIRMADA.

### Adicionado - 25/09/2026 (onda 4: implantacao e tenant)
- `/app/catalogo` (rotas, tabelas, versoes, checklists, etapas padrao) e `/app/configuracao` (status da configuracao); rota de plataforma para o catalogo de referencia; bootstrap de organizacao com CNPJ e guarda de nome parecido; env fail-closed; `npm run preflight`; limite de upload 4 MB.
- Docs: `docs/deployment/*` (variaveis, auth/SMTP, runbook de implantacao, rollback, drift), `docs/pilot/SMART-HUMAN-ACCEPTANCE-TEST.md`, `SMART-PILOT-INCIDENTS.md`.
- Testes: unit 229; `catalog-publish-rollback.sql` 40/40.

### Seguranca - 25/09/2026 (PREPARADA, NAO APLICADA)
`20260929_catalog_publish_v1`: publicar tabela/checklist era impossivel sem SQL; INSERT permitia versao ja publicada.

### Adicionado — 20/09/2026 (Next wave V3, preparado)

- CEP automatico no cadastro/edicao de cliente (rota `/api/cep`, ViaCEP, sem chave); passo a passo em `/app/comercial`.
- Migrations preparadas (nao aplicadas): `20261004_commercial_bulk_import_v1` (importacao atomica), `20261005_ai_import_metering_v1` (memoria de mapeamento + creditos/metering de IA), `20261006_action_center_v1` (Central de atencao); harnesses rollback-only.
- Biblioteca `src/lib/ai-import` (provider-agnostic, adapter Gemini sem chave) e `src/lib/attention-rules.ts`; pagina `/app/atencao`.
- Auditoria e desenho da integracao de payout: `docs/audits/AUDIT-2026-09-20-NEXT-WAVE-V3.md`.


### Alterado — 20/09/2026 (reestruturação de produto V1)
- Menu principal reorganizado por áreas de negócio.
- Adicionados hubs CRM, Operacional, Cadastros e Relatórios usando módulos já existentes.
- Nenhum DDL, dado real, secret ou regra financeira alterados.
- Protocolo de tripla revisão e economia de Claude registrado em RULES/CLAUDE-LONG-RUN.
- Roadmap consolidado em `docs/PRODUCT-UX-RESTRUCTURE-V1.md`.


### Auditado — 20/09/2026 (pré-Wave B)
- Schema LIVE revisado em modo somente leitura.
- Confirmado reuso possível de commercial_entities/relationships/channels, network_split_rule_versions e commission_rule_components.
- Lacunas registradas: vendedor/perfil comercial e fatores versionados.
- Nenhuma DDL aplicada; Claude não utilizado.


### Preparado — 20/09/2026 (Seller/SUB + Fatores)
- `20261007_seller_commercial_profile_v1.sql`: Grupo de Vendedor ≠ Grupo de Comissão, cadastro PF/PJ/SUB e regra SUB versionada.
- `20261008_commercial_factors_v1.sql`: fatores daily/fixed, batches versionados e resolver para CRM.
- Dois contratos SQL adicionados.
- Ambos executados rollback-only sem erro; zero persistência.
- Publicação financeira/configuração protegida por RPC; inserts autenticados começam em draft.
- Vercel READY; Claude não utilizado.
- Aguardando autorização explícita para DDL LIVE.


### LIVE — 20/09/2026 (Seller/SUB + Fatores)
- Aplicadas `seller_commercial_profile_v1` e `commercial_factors_v1`.
- Contratos pós-apply passaram.
- Security advisor sem WARN/ERROR novo.
- UI de Vendedores/SUB e Fatores adicionada; importação de fatores CSV/XLSX inicial disponível.
- Nenhum Claude utilizado.


### Preparado — 20/09/2026 (Componentes + Tipos de Contrato)
- Preparada camada component-aware de comissão: À Vista, Diferido, Bônus 1/2/3, Plástico e Seguro fixo.
- Suporte preparado para % e R$, regras por Grupo de Comissão, desconto/imposto e escopo organização/banco/convênio/tabela.
- Preparado gerenciamento tenant-aware de Tipo de Contrato com flags de esteira/comissão.
- Preparado pacote de índices das novas FKs de Seller/SUB/Fatores.
- Três contratos rollback-only passaram; zero persistência.
- Claude não utilizado.


### LIVE — 20/09/2026 (Componentes + Tipos de Contrato)
- Componentes de comissão, tipos tenant-aware e índices adicionais aplicados LIVE.
- Refin/Portabilidade incluído no catálogo global.
- Contratos pós-apply passaram; security advisor sem WARN/ERROR novo.
- UI de Tipos de Contrato e regras por componente iniciada.
- Claude não utilizado.


### Preparado — 20/09/2026 (Smart Commercial Import V1)
- Parser determinístico de planilha comercial adicionado.
- Modelo XLSX dinâmico passa a usar nomes reais dos Grupos de Comissão.
- RPC atômica preparada para catálogo/tabela/condições/componentes/fatores.
- Generic Repasse 1/2/3 é tratado como ambiguidade, não como grupo.
- 20261012 passou em rollback-only; zero persistência.
- Claude ainda não utilizado.


### LIVE/UX — 20/09/2026 (Smart Import)
- `smart_commercial_import_v1` aplicado LIVE.
- Contract pós-apply passou; security advisor sem WARN/ERROR novo.
- Tela guiada de importação inteligente adicionada.
- CSV/XLSX com prévia, perguntas condicionais e confirmação antes do RPC atômico.
- Repasse 1/2/3 legado nunca é associado silenciosamente a Grupo de Comissão.
- Tabela fica em rascunho após a carga.
- Claude não utilizado até este ponto.


### Estabilizado — 20/09/2026 (Smart Import build)
- Produção Vercel novamente READY.
- Experimento de cálculo econômico detalhado na prévia revertido após erro de build; core Smart Import preservado.
- Banco LIVE não sofreu rollback nem alteração adicional.
- Próximo trabalho transferido para Claude apenas por necessidade real de ambiente local: XLS legado/PDF + dependências + testes com arquivos reais.

### Adicionado — 20/09/2026 (Smart Import XLS + PDF)

- Leitura de `.xls` legado (`@e965/xlsx`) e de PDF com camada de texto (`unpdf`) para o Smart Commercial Import, reaproveitando o mesmo parser.
- Guardas de arquivo: formato por magic bytes, inspecao de zip, limites de tamanho/linhas/colunas, nome seguro.

### Segurança — 20/09/2026

- XLSX com mais de 1.000 linhas era cortado em silencio; agora recusado acima do teto. Coluna de dinheiro nao reconhecida recusa o arquivo. Datas de calendario invalidas recusadas.
