# Checklist do piloto - Smart Promotora (1 operador real)

Marque cada item. Um item não marcado em "ANTES" bloqueia o dia 1.

## ANTES DO PILOTO
Owner (detalhes em `SMART-OWNER-SETUP.md`):
- [ ] Migration `20260928_revoked_actor_dispatch_v1` revisada e aplicada (necessária antes de ativar o worker; não bloqueia o operador).
- [ ] `<APP_ORIGIN>` definido e sistema publicado (hoje NÃO há deploy de produção).
- [ ] Supabase Auth: Site URL, Redirect URL, SMTP, confirmação de e-mail, cadastro público desligado, política de senha.
- [ ] `NEXT_PUBLIC_SITE_URL` na hospedagem.
- [ ] Organização Smart Promotora criada (uma vez) e administrador com primeiro login feito.
- [ ] Catálogo comercial publicado (tabela + versão publicada + checklist de documentos + etapas da operação). Configuração deve mostrar tudo OK.
- [ ] Supervisor e operador convidados, com senha criada, aparecendo "Ativo" em Equipe.
- [ ] Teste de aceitação com dados fictícios feito (passo 7 do OWNER-SETUP), incluindo desativar/reativar o operador.
- [ ] Decisão comercial: o operador pode ver comissão esperada? (hoje: NÃO; nenhuma tela mostra comissão ao operador.)
- [ ] `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md` seção 3 (teste humano de convite) executada e registrada.
Fora do piloto (NÃO ativar): segredo do worker, agendador, integrações com bancos, Bevicred, 2Tech.

## DIA 1
- [ ] Supervisor ao lado do operador durante o primeiro atendimento real.
- [ ] Operador entra, vê "Precisa da sua atenção" e o menu reduzido (sem Equipe/Integrações/Financeiro).
- [ ] Um lead real registrado -> convertido -> simulado -> proposta criada.
- [ ] Documentos enviados e anexados; supervisor validou; proposta enviada para a operação.
- [ ] Anotar toda mensagem confusa ou tela em que o operador ficou parado (horário e o que tentou).
- [ ] Nenhum dado de cliente fora do sistema.

## DIAS 2-3
- [ ] Operador trabalha sozinho; supervisor confere "Precisa da sua atenção" no início e no fim do dia.
- [ ] Conferir que nenhum lead ficou parado 2+ dias e que nenhuma proposta ficou em rascunho sem motivo.
- [ ] Rever as anotações do dia 1: priorizar as que travaram o operador.
- [ ] Testar recuperação de senha com o operador (sem senha nova em papel).
- [ ] Confirmar que ninguém vê comissão/financeiro fora do perfil.

## FIM DA PRIMEIRA SEMANA
- [ ] Números: leads registrados, convertidos, propostas criadas, enviadas para a operação.
- [ ] Lista de atritos: P0 (travou), P1 (atrapalhou), P2 (incômodo).
- [ ] Decidir: adicionar mais operadores? ligar worker/integrações? decidir regra de comissão?
- [ ] Revisar Equipe: alguém que saiu foi desativado?
- [ ] Guardar as referências de erro ("Algo não funcionou") e enviar para correção.

## Critério para parar o piloto imediatamente
Operador vê dados de outra organização; alguém consegue marcar proposta como paga; comissão aparece para o operador; convite/senha vaza; perda de dados. Nestes casos: desativar o acesso em Equipe e avisar o agente/ChatGPT.
