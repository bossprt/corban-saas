# Smart Promotora - configuração do Owner (Josicleuton)

Nada aqui foi feito pelo agente. São ações suas, fora do repositório. Valores entre `< >` são seus.

## 0. Situação verificada no banco (somente leitura, 2026-09-25)
- A organização **Smart Promotora Ltda. existe e está ativa** no LIVE. Não recriar.
- Existe 1 administrador de plataforma ativo (necessário para criar a organização).
- O catálogo global está parcial: bancos carregados; provedores, convênios, produtos e tipos de documento ainda exigem dados reais.

## 1. Decidir e registrar
- `<APP_ORIGIN>`: o endereço público do sistema (exemplo: `https://app.suaempresa.com.br`). Sem barra no final.
- `<E-MAIL_REMETENTE>`: endereço que envia os convites.
- E-mail do primeiro administrador da Smart (pode ser o seu).

## 2. Supabase - Authentication (leia `docs/runbooks/AUTH-AND-INVITE-RUNBOOK.md` para o passo a passo completo)
1. URL Configuration: Site URL = `<APP_ORIGIN>`; Redirect URLs = `<APP_ORIGIN>/auth/definir-senha` (e `<APP_ORIGIN>/auth/confirm` se usar o template com token-hash).
2. SMTP próprio configurado e testado (o envio padrão do Supabase não serve para produção).
3. "Confirm email" LIGADO. Cadastro público DESLIGADO (todos entram por convite).
4. Política de senha: mínimo 10 caracteres; proteção contra senhas vazadas ligada se o plano permitir.
5. Na hospedagem, variável de servidor `NEXT_PUBLIC_SITE_URL=<APP_ORIGIN>`.

## 3. Completar o catálogo de referência (administrador de plataforma)
Passos exatos, com os dois comandos e as respostas possíveis: `docs/deployment/SMART-DEPLOYMENT-RUNBOOK.md`, seções 7 e 8.
- Bancos já estão carregados. Provedores, convênios, produtos e tipos de documento continuam vazios e precisam dos seus dados reais (modelo: `docs/deployment/reference-catalog.template.json`). O sistema não inventa nada.
- A organização Smart já existe. NÃO execute novamente o bootstrap de organização.

## 4. Primeiro login do administrador da Smart
1. Abra o convite, crie a senha (10+ caracteres), entre.
2. Você deve ver "Visão geral" com a organização Smart Promotora e o menu completo, incluindo **Equipe**.
3. Se aparecer "Acesso ainda não liberado": o convite ainda não foi aceito com este e-mail; use "Verificar novamente".

## 5. Montar a equipe (menu Equipe)
1. Convidar o supervisor (perfil Supervisor) e o operador (perfil Operador) com os e-mails deles.
2. Cada um recebe o e-mail, cria a senha e entra. Confira em Equipe: situação "Ativo".
3. O operador NÃO deve ver os menus Equipe, Integrações, Financeiro, Importações, Catálogo, Rede, Configuração.

## 6. Preparar o catálogo antes do operador entrar (pelo navegador, sem SQL)
Menu **Catálogo** (administrador/gerente; checklist também o supervisor) e **Configuração** (mostra o que falta):
1. "Criar etapas padrão" (esteira). 2. Criar a rota comercial. 3. Criar a tabela, uma versão com taxa/coeficiente e prazos REAIS e **Publicar**. 4. Criar o checklist, adicionar os documentos e publicar.
Publicar exige a migration `20260929_catalog_publish_v1` aplicada (revisão do ChatGPT). O catálogo comercial NÃO liga nenhum banco; é só o cadastro usado nas simulações.

## 7. Teste de aceitação (sem cliente real): roteiro completo em `SMART-HUMAN-ACCEPTANCE-TEST.md`
Use dados fictícios e apague nada: o sistema não apaga. Prefira fazer isto ANTES do operador real.
1. Como operador: novo lead (nome fictício) -> converter (CPF de teste válido) -> simular -> criar proposta.
2. Como supervisor: preparar checklist, anexar/validar documentos, enviar para a operação.
3. Operação: iniciar digitação -> marcar enviado.
4. Como administrador: Equipe -> desativar o operador; o operador deve perder acesso na próxima ação; reativar.
5. Não existe botão de "marcar como pago": isso é esperado.

## 8. Não ative ainda
Segredo do worker e agendador (`docs/integrations/WORKER-DEPLOYMENT.md`) e integrações reais: o piloto interno não depende deles.

## Se algo der errado
- Convite não chegou: SMTP não configurado ou na caixa de spam; use "Reenviar" em Equipe.
- Link inválido: peça novo convite. Links expiram em 7 dias.
- Organização criada duas vezes: não apague; avise o agente/ChatGPT para tratar (o sistema não tem exclusão de organização).
