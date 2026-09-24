# RULES — CORBAN

Operating rules for any AI or developer working in this repository. Rewritten on 2026-09-24 during the product reset; the
earlier version pointed to ChatGPT-era master documents that described an architecture the code never had (removed,
recoverable from the tag `backup/docs-pre-cleanup`).

---

# 0. Read first

Before changing architecture, schema, authorization, financial logic or domain behavior, read in this order:

1. `/.ai/MAPA-OPERACAO.md` — product source of truth (owner interview, approved by the owner).
2. `/.ai/DECISIONS.md` — architectural decisions (ADRs); the latest ADR on a topic wins.
3. `/.ai/CURRENT-TASK.md` — current phase and its state.
4. This file.

What is implemented is decided only by the code, the versioned migrations and the live database. Documents describe
intent; never describe planned capability as implemented.

---

# 1. Human Gate

- Explain before executing and wait for the owner's approval: code changes, migrations, commands with side effects.
- Plans or summaries pasted into the chat are for reading and discussion, not orders.
- No destructive migration, production publication, secret, significant spend or irreversible external action without
  explicit approval.
- Removal of legacy objects: listed proposal, owner approval, backup, versioned migration (or commit for files).
- Never modify `main` directly; work in feature branches with stacked PRs.

---

# 2. Non-negotiable rules

1. Every business table carries `organization_id`; tenant isolation is fail-closed through RLS. Never weaken RLS to
   make a feature work.
2. Authorization lives in the database (RLS, `has_permission`, SECURITY DEFINER RPCs); the screen only hides.
3. Writes to governed tables go through RPCs that set a governed flag (`corban.*_rpc`); guard triggers refuse direct
   writes and deletes.
4. Money is `numeric` in the database and exact decimal strings / rationals in TypeScript. Never floating point.
5. Financial history is immutable; corrections are new compensating entries.
6. Every database change is a versioned migration, tested on the local database rebuilt from scratch, with a security
   contract in `tests/security/`. A migration applied in production is never edited.
7. CPF never in a URL; personal data (CPF, salary, margin) only for who needs it.
8. Corban works standalone. The DeskcommCRM integration is optional and never a dependency.
9. AI suggestions never publish financial truth without deterministic validation and the Human Gates above.

---

# 3. Each phase

- Ends working end to end and proven on screen (Playwright), plus unit tests, `tsc`, lint and build.
- Updates `/.ai/CURRENT-TASK.md` and `/.ai/CHANGELOG.md`; new architectural decisions go to `/.ai/DECISIONS.md`.
- Reports clearly what was done, what was not, and the next step.

---

# 4. Stack facts

- Next.js 16 (App Router; read `node_modules/next/dist/docs/` before writing Next code), Tailwind v4 tokens.
- Supabase Postgres with RLS; migrations in `supabase/migrations/` named `YYYYMMDDHHMMSS_description.sql`.
- Tests: `tests/unit` (`npm run test:unit`), `tests/security/*.sql` (contracts), `tests/e2e` (Playwright).
