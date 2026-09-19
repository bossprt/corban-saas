# Teste de aceitação humano - Smart Promotora

Executar no ambiente publicado, com DADOS FICTÍCIOS (nome inventado, CPF de teste válido, ex.: 529.982.247-25, telefone inventado). Um humano, navegador comum, sem terminal (exceto os dois comandos de plataforma do runbook). Anote data/hora e o que aconteceu; se algo falhar, use `SMART-PILOT-INCIDENTS.md`.
Marque OK / FALHOU e copie o texto exato de qualquer mensagem de erro.

## A. Administrador da Smart
1. [ ] Abrir `<APP_ORIGIN>/login`. Aparece o login com "Esqueci minha senha".
2. [ ] Criar a senha pelo convite (link do e-mail → "Criar senha") e entrar.
3. [ ] Visão geral mostra o nome "Smart Promotora" e o menu completo (Leads, Clientes, Catálogo, Simulações, Propostas, Documentos, Operação, Rede comercial, Importações, Integrações, Financeiro e conciliação, Equipe, Configuração).
4. [ ] **Configuração**: lista os itens pendentes (nenhum marcado "Pronto" sem ser verdade).
5. [ ] **Catálogo → Etapas**: "Criar etapas padrão" → mensagem verde; a seção passa a "Todas as etapas existem".
6. [ ] **Catálogo → Rotas**: criar a rota (banco/provedor/convênio/produto/modalidade reais da Smart).
7. [ ] **Catálogo → Tabelas**: criar tabela, criar versão com taxa/coeficiente e prazos reais, **Publicar** → "Versão publicada". Tentar publicar de novo: não há botão (versão já publicada).
8. [ ] **Catálogo → Checklist**: criar checklist, adicionar 2 documentos (1 obrigatório, 1 opcional), publicar.
9. [ ] **Configuração** agora mostra esses itens como "Pronto".
10. [ ] **Equipe**: convidar o supervisor (Supervisor) e o operador (Operador). Aparecem em "Convites pendentes". Reenviar um deles; cancelar e recriar outro.
11. [ ] Confirmar que o administrador NÃO consegue alterar o próprio perfil nem desativar a si mesmo (botões ausentes).

## B. Operador (conta do operador, navegador em outra janela anônima)
1. [ ] Criar a senha pelo convite e entrar.
2. [ ] O menu mostra só: Visão geral, Leads, Clientes, Simulações, Propostas, Documentos, Operação. NÃO mostra Equipe, Integrações, Financeiro, Catálogo, Importações, Rede, Configuração.
3. [ ] Abrir `<APP_ORIGIN>/app/equipe` digitando o endereço: aparece "restrita aos perfis administrador e gerente" (não erro técnico).
4. [ ] **Leads → Novo lead** (nome fictício + telefone): mensagem verde "Lead registrado"; o lead aparece; buscar por nome encontra.
5. [ ] Converter em cliente com o CPF de teste: "Lead convertido"; clicar duas vezes rápido não cria dois clientes (Clientes mostra 1).
6. [ ] **Simulações**: escolher o cliente e a tabela publicada, valor e prazo → "Simulação registrada"; parcela calculada (ou "Não calculado" se a versão não tem coeficiente); nenhuma comissão aparece.
7. [ ] **Criar proposta** (clicar 2 vezes rápido): fica 1 proposta; a simulação mostra "Proposta criada".
8. [ ] Abrir a proposta: situação e próximo passo em português ("Rascunho — Prepare o checklist...").
9. [ ] **Documentos**: enviar um PDF pequeno (< 4 MB) do cliente, tipo do checklist → "Documento enviado". Tentar um arquivo .txt renomeado para .pdf → recusado com mensagem clara. Tentar arquivo > 4 MB → recusado com mensagem clara.
10. [ ] Na proposta: "Preparar checklist" → itens aparecem; anexar o documento ao item correspondente.
11. [ ] Não existe botão "marcar como pago" em nenhuma tela.
12. [ ] Visão geral mostra "Meus leads" e "Minhas propostas" (só os do operador) e o painel "Precisa da sua atenção" coerente.

## C. Supervisor
1. [ ] Entrar. O menu inclui Catálogo, Importações, Integrações e Financeiro e conciliação; NÃO inclui Equipe, Rede, Configuração.
2. [ ] Visão geral: "Precisa da sua atenção" com contagens; clicar leva à tela certa.
3. [ ] **Propostas**: a proposta do operador com documentos pendentes; **validar** o documento anexado (botão do supervisor).
4. [ ] Depois de todos os obrigatórios validados: "Pronta para a operação" → **Enviar para a operação**.
5. [ ] **Operação**: o caso aparece "Na fila de digitação"; o operador inicia a digitação; supervisor marca enviado e depois aprova. Aprovada NÃO vira paga.
6. [ ] **Integrações**: só provedores "LOCAL / TESTE - não é banco"; painel de prontidão diz que o processamento não está pronto (esperado no piloto inicial).
7. [ ] **Financeiro**: "Comissão esperada" aparece como previsão; nada "recebido".
8. [ ] Tentar abrir Equipe pelo endereço: mensagem de acesso restrito.

## D. Acesso e segurança
1. [ ] Administrador: Equipe → **Desativar acesso** do operador. Na próxima ação, o operador é barrado (volta ao login/tela de acesso).
2. [ ] Administrador: **Reativar acesso**; o operador volta a entrar.
3. [ ] Operador: Login → "Esqueci minha senha" com o próprio e-mail e com um e-mail inexistente: a mesma mensagem nos dois casos; o e-mail real chega; a nova senha funciona.
4. [ ] Abrir um link de convite já usado: volta ao login com aviso de link inválido.

## E. Saúde
1. [ ] `<APP_ORIGIN>/api/health` mostra `status ok`, sem nenhuma configuração.

## Resultado
- Todos os itens A–E OK: liberado para 1 operador real (após o checklist ANTES em `SMART-PROMOTORA-PILOT-CHECKLIST.md`).
- Qualquer FALHOU em B ou C: corrigir antes. FALHOU em D: parar e chamar o agente/ChatGPT.
