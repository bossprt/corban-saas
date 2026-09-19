# Smart Promotora - configuração do Owner (Josicleuton)

Nada aqui foi feito pelo agente. São ações suas, fora do repositório. Valores entre `< >` são seus.

## 0. Situação verificada no banco (somente leitura, 2026-09-25)
- A organização **Smart Promotora NÃO existe** ainda. Existem apenas duas organizações de teste ("Tenant A/B - Teste RLS").
- Existe 1 administrador de plataforma ativo (necessário para criar a organização).
- Nenhum lead, cliente, proposta ou dado de negócio no banco.

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

## 3. Criar a organização Smart Promotora (uma única vez)
Só o administrador de plataforma pode. Faça logado como ele, no navegador:
1. Abra o sistema e entre. Abra o console do navegador (F12).
2. Execute (troque os valores):
   `fetch('/api/admin/organizations',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'<email-do-admin-smart>',organizationName:'Smart Promotora',organizationDocument:'<CNPJ>',fullName:'<nome>'})}).then(r=>r.json()).then(console.log)`
3. Resposta esperada: `{ "organizationId": "..." }` com status 201. O e-mail do administrador recebe o convite (depende do SMTP do item 2).
4. NÃO repita o comando: cria outra organização. Se falhar, veja o item "Se algo der errado".

## 4. Primeiro login do administrador da Smart
1. Abra o convite, crie a senha (10+ caracteres), entre.
2. Você deve ver "Visão geral" com a organização Smart Promotora e o menu completo, incluindo **Equipe**.
3. Se aparecer "Acesso ainda não liberado": o convite ainda não foi aceito com este e-mail; use "Verificar novamente".

## 5. Montar a equipe (menu Equipe)
1. Convidar o supervisor (perfil Supervisor) e o operador (perfil Operador) com os e-mails deles.
2. Cada um recebe o e-mail, cria a senha e entra. Confira em Equipe: situação "Ativo".
3. O operador NÃO deve ver os menus Equipe, Integrações, Financeiro, Importações, Catálogo, Rede, Configuração.

## 6. Preparar o catálogo antes do operador entrar
O operador só consegue simular com uma tabela comercial **publicada**. Se "Simulações" mostrar "Nenhuma tabela comercial publicada", o cadastro comercial (banco, convênio, tabela, versão publicada, checklist de documentos e etapas da operação) ainda precisa ser feito por quem administra o catálogo. Confira em Configuração ("Prontidão do tenant"): todos os itens devem estar OK.

## 7. Teste de aceitação (sem cliente real)
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
