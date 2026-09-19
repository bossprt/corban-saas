# Supabase Auth e SMTP - configuração exata (ação do Owner)

Nada aqui foi executado pelo agente. `<APP_ORIGIN>` = endereço público do sistema, ainda NÃO definido (exemplo: `https://app.suaempresa.com.br`, sem barra final e sem caminho).

## 1. URLs que o código realmente usa
| Uso | URL completa | Onde no código |
|---|---|---|
| Destino do link do convite | `<APP_ORIGIN>/auth/definir-senha` | `src/lib/team.server.ts` (`sendInvitationEmail`) e `/api/admin/organizations` (convite do primeiro administrador) |
| Destino do link de recuperação de senha | `<APP_ORIGIN>/auth/definir-senha` | `src/app/login/recuperar/actions.ts` |
| Rota do template com token-hash (opcional) | `<APP_ORIGIN>/auth/confirm?token_hash={{ .TokenHash }}&type=invite` (convite) e `...&type=recovery` (recuperação) | `src/app/auth/confirm/route.ts` (tipos aceitos: `invite`, `recovery`, `magiclink`, `email`) |
Não há nenhuma outra rota de retorno. O destino depois de validar é FIXO (`/auth/definir-senha`); o código ignora qualquer parâmetro `next`/`redirect`.

## 2. Passo a passo no painel do Supabase
1. **Authentication → URL Configuration**
   - Site URL: `<APP_ORIGIN>`
   - Redirect URLs: adicione `<APP_ORIGIN>/auth/definir-senha` e, só se usar o template com token-hash, `<APP_ORIGIN>/auth/confirm`.
2. **Authentication → Sign In / Providers → Email**
   - "Confirm email": LIGADO (o aceite de convite exige e-mail confirmado).
   - "Allow new users to sign up": DESLIGADO no piloto (todos entram por convite).
3. **Authentication → Emails → SMTP Settings**: ligue o SMTP personalizado (checklist da seção 3). Faça o "send test email".
4. **Authentication → Emails → Templates** (opcional, mais robusto): em "Invite user" e "Reset password", troque o link pelo formato token-hash da tabela acima. Mantenha o resto do texto.
5. **Authentication → Attack Protection / Password**: comprimento mínimo 10; ligue "Leaked password protection" se o plano permitir. O formulário do sistema pede 10+, mas a regra final é do Supabase.
6. **Authentication → Rate Limits**: confira o limite de e-mails por hora; convites usam esse limite (o banco ainda limita 20 convites/hora por administrador).
7. Na hospedagem: `NEXT_PUBLIC_SITE_URL=<APP_ORIGIN>` (ver `ENVIRONMENT-VARIABLES.md`).

## 3. Checklist de SMTP (preencha; não cole senha em chat)
| Campo | Valor (você) |
|---|---|
| Host | `<smtp.seuprovedor.com>` |
| Porta | `<587 ou 465>` |
| Usuário | `<usuario>` |
| Senha | `<no painel do Supabase apenas>` |
| E-mail remetente | `<no-reply@seudominio>` |
| Nome do remetente | `Corban OS - Smart Promotora` |
| SPF/DKIM do domínio remetente | `<configurados no DNS do seu domínio>` |
Fluxos que dependem de SMTP: convite (equipe e primeiro administrador), recuperação de senha, confirmação de e-mail. Sem SMTP nenhum deles chega ao destinatário.

## 4. Como verificar (sem terminal)
- Convide um e-mail seu em Equipe → o e-mail chega, o link abre `<APP_ORIGIN>/auth/definir-senha`, a senha é criada e você entra.
- Login → "Esqueci minha senha" → resposta neutra → e-mail → mesma tela de senha.
- Link antigo/inválido → volta ao login com aviso de link inválido.
- Se o link cair na página de login sem pedir senha: a Redirect URL não está na lista (passo 1).
