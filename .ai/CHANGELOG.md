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
