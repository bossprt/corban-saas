# Runbook - Auth configuration and the first real invitation (Owner steps)

Nothing in this file was executed. It lists exactly what the Owner must configure OUTSIDE the repository before a human pilot, and how to test it.
Placeholders in angle brackets are values only the Owner knows; the repository does not contain them.

## 0. Values you must decide first
- `<APP_ORIGIN>`: the public origin of the deployed app, for example `https://app.example.com` (scheme + host, no path, no trailing slash). Not decided yet.
- `<SENDER_ADDRESS>`: the sender address the invitation e-mails come from.

## 1. What the code actually requires
| Where the code uses it | Exact value |
|---|---|
| Invitation e-mail redirect (`sendInvitationEmail`, `src/lib/team.server.ts`) | `<APP_ORIGIN>/auth/definir-senha` |
| Password recovery redirect (`requestPasswordReset`, `src/app/login/recuperar/actions.ts`) | `<APP_ORIGIN>/auth/definir-senha` |
| Optional token-hash e-mail templates (handler `src/app/auth/confirm/route.ts`) | `<APP_ORIGIN>/auth/confirm?token_hash={{ .TokenHash }}&type=invite` (invitation) and `...&type=recovery` (recovery) |
| Origin used to build those redirects | env `NEXT_PUBLIC_SITE_URL` (recommended; without it the request `Origin` header is used) |

There is no other callback route. Nothing else needs to be allow-listed.

## 2. Supabase Dashboard steps
1. Project -> Authentication -> URL Configuration.
   - Site URL: `<APP_ORIGIN>`
   - Redirect URLs (add): `<APP_ORIGIN>/auth/definir-senha` and, only if you use the token-hash templates, `<APP_ORIGIN>/auth/confirm`.
2. Authentication -> SMTP Settings (or Emails -> SMTP): enable custom SMTP with your provider's host, port, user and password, sender `<SENDER_ADDRESS>`. The built-in sender is heavily rate limited and not meant for production. Send yourself a test e-mail from the dashboard.
3. Authentication -> Sign In / Providers -> Email: keep "Confirm email" ON (the acceptance of an invitation requires a confirmed address). Decide whether public sign-up stays ON; for a closed pilot turn it OFF, because every legitimate user arrives by invitation.
4. Authentication -> Password policy: minimum length 10 (matches the form) and enable "Leaked password protection" if the plan offers it. Supabase Auth is the final authority on password rules; our form only checks length as a courtesy.
5. Optional but recommended: Authentication -> Email Templates. In "Invite user" and "Reset password" replace the link with the token-hash form from the table above. Then the link is verified by our server route and no token travels in the URL fragment.
6. Hosting environment (server-side only): set `NEXT_PUBLIC_SITE_URL=<APP_ORIGIN>`.

## 3. Real invitation test (do it once SMTP works)
Use two addresses you control: an admin account and a test address.
1. Sign in as an organization admin. Open Equipe.
2. Invite the test address as Operador. Expected banner: "Convite criado e e-mail enviado". The address appears under "Convites pendentes".
3. Open the e-mail. The link must go to `<APP_ORIGIN>/auth/definir-senha` (or `/auth/confirm` -> `/auth/definir-senha`).
4. Choose a password of 10+ characters. Expected: you land inside the app.
5. Equipe (as admin) now lists the test address as Ativo / Operador; the invitation is gone from "Pendentes"; "Últimas alterações" shows "Convite aceito".
6. Sign in as the test user: the menu must NOT show Equipe, Integrações or Financeiro.
7. As admin, "Desativar acesso" for the test user. The test user's next click must fail or return to the access-pending screen; no data may load.
8. As admin, "Reativar acesso". The test user regains access on the next request.
9. Recovery: sign out, Login -> "Esqueci minha senha", enter the test address. The confirmation text is the same for an unknown address. The e-mail link leads to `/auth/definir-senha`.
10. Negative checks: open an old link again (must say the link is invalid), open `<APP_ORIGIN>/auth/confirm?token_hash=abc&type=invite` (must return to login with a link error).

Record the date and who ran it in `.ai/CURRENT-TASK.md`. If any step fails, do not proceed to the pilot.

## 4. Known limits
- An invited address that already has an account receives no e-mail; the person sees the access after signing in (`/organizacao` or the app).
- E-mail send rate is Supabase Auth's limit; the database also limits 20 invitations per admin per hour.
- Password recovery gives the same answer for known and unknown addresses, but response time is not equalised.
