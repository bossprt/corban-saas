# Deploy — first production deploy and operation

Owner steps. Nothing here is executed by an agent without explicit approval. Consolidates, on 2026-09-24, the earlier
deployment runbook, Supabase Auth configuration, rollback notes and invite runbook (recoverable from the tag
`backup/docs-pre-cleanup`). Environment variables stay in [`deployment/ENVIRONMENT-VARIABLES.md`](./deployment/ENVIRONMENT-VARIABLES.md).

`<APP_ORIGIN>` = public address of the system (https, no trailing slash, no path).

## Starting state (checked 2026-09-24)

- Database (Supabase `nhjfrcttzxnphhizlnmc`): every migration in `supabase/migrations/` is applied, including
  `catalog_publish_v1` and the F4–F6 migrations. Production migrations are applied only through the md5-checked
  workflow described in `.ai/CURRENT-TASK.md`.
- Global reference catalog (banks, products, document types) is empty until step 6.

## 1. Hosting (Vercel)

- Project from `bossprt/corban-saas`. Production branch chosen by the owner; never `main` without review.
- Build: `next build --webpack` (from `package.json`); Node 20 or 22; no `vercel.json` needed. Routes run on the Node
  runtime; `proxy.ts` (repository root) is the Next 16 middleware.
- Uploads go through a server action: documents are limited to 4 MB (`src/lib/documents.ts`), because Vercel rejects
  bodies above 4.5 MB (`serverActions.bodySizeLimit` is 5 MB in `next.config.ts`). Larger files would need direct
  upload to Storage.

## 2. Environment variables (Production)

- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
- `SUPABASE_SERVICE_ROLE_KEY` — sensitive, server only, never with a `NEXT_PUBLIC_` prefix.
- `NEXT_PUBLIC_SITE_URL=<APP_ORIGIN>` — required in production.
- Check locally first with the same values in an uncommitted `.env.production.local`: `npm run preflight -- --production`.

## 3. Deploy and smoke test

- `<APP_ORIGIN>/api/health` answers `{"status":"ok","app":"ok","database":"ok","auth":"ok"}` (503 `degraded` when the
  database does not answer). No configuration is exposed.
- `<APP_ORIGIN>/login` shows the login screen.

## 4. Supabase Auth and SMTP

URLs the code uses: the invite (`src/lib/team.server.ts`, `/api/admin/organizations`) and the password recovery
(`src/app/login/recuperar/actions.ts`) both land on `<APP_ORIGIN>/auth/definir-senha`. Optional token-hash templates use
`<APP_ORIGIN>/auth/confirm?token_hash={{ .TokenHash }}&type=invite|recovery` (`src/app/auth/confirm/route.ts`). The
destination after validation is fixed; `next`/`redirect` parameters are ignored.

1. Authentication → URL Configuration: Site URL `<APP_ORIGIN>`; Redirect URLs `<APP_ORIGIN>/auth/definir-senha` (plus
   `<APP_ORIGIN>/auth/confirm` if the token-hash templates are used).
2. Authentication → Providers → Email: "Confirm email" on; "Allow new users to sign up" off (everyone enters by invite).
3. Authentication → Emails → SMTP: custom SMTP on (the built-in sender is rate limited); SPF/DKIM on the sender domain;
   send a test email. The SMTP password is typed only in the Supabase panel, never in chat.
4. Optional: "Invite user" and "Reset password" templates switched to the token-hash link.
5. Password minimum length 10; leaked-password protection on if the plan allows.
6. Rate limits: invites use the email limit; the database also caps 20 invites per hour per administrator.

Check: invite your own email from Equipe → the link opens `/auth/definir-senha` → create the password → enter. Login →
"Esqueci minha senha" → neutral answer → email → same screen. An old or invalid link returns to login with a warning. If
the link falls on the login page without asking for a password, the Redirect URL is missing (step 1).

## 5. Reference catalog (once, platform administrator)

Logged in as the platform administrator, in the browser console:
`fetch('/api/admin/reference-catalog',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(<content>)}).then(r=>r.json()).then(console.log)`

Content: a copy of [`deployment/reference-catalog.template.json`](./deployment/reference-catalog.template.json) with every
`<...>` replaced by real codes and names. Idempotent (a repeat updates names by code; nothing is deleted). Expected 201
with counts; check with a GET on the same route.

## 6. First organization and administrator (once)

`fetch('/api/admin/organizations',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'<admin-email>',organizationName:'<name>',organizationDocument:'<CNPJ>',fullName:'<name>'})}).then(r=>r.json()).then(console.log)`

- CNPJ must have valid check digits; stored as digits only; unique.
- Answers: `201 {organizationId}`; `409 organization_document_exists`; `409 similar_organization_exists` (repeat with
  `"confirmSimilarName":true` only if it really is another company); `400 invalid_cnpj`; `400 invite_failed`.
- Never repeat after a 201. The invite depends on step 4.
- There is no public first-admin endpoint by design.

## 7. First login

The administrator sets the password from the invite; Configuração shows what is missing (stages, commercial route,
table and version with real rates, document checklist, team invites).

## Recovery (rollback) rules

- Nothing is deleted to recover. "Rollback" means deactivating (a user access, a condition), promoting the previous
  Vercel deployment, or writing a compensating record.
- A Vercel rollback does not touch the database; migrations are additive and never edited once applied.
- Deactivating a user's access is immediate and enforced by the database.
