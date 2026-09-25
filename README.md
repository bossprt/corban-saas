# Corban

Management system for a consigned-credit bank correspondent (corban): clients, proposals and pipeline, banks, rate
tables and agreements, commercial conditions and factors, commission calculation, commission receipt and
reconciliation, and seller payout. Multi-tenant; used first by the owner's company and later sold to other corbans.

## Where to start

1. [`.ai/MAPA-OPERACAO.md`](./.ai/MAPA-OPERACAO.md) — product source of truth (owner-approved operation map).
2. [`.ai/RULES.md`](./.ai/RULES.md) — operating rules.
3. [`.ai/DECISIONS.md`](./.ai/DECISIONS.md) — architectural decisions.
4. [`.ai/CURRENT-TASK.md`](./.ai/CURRENT-TASK.md) — current phase and state.

What is implemented is decided by the code, the migrations in `supabase/migrations/` and the live database.

## Stack

- Next.js 16 (App Router, webpack), React, Tailwind v4.
- Supabase: Postgres with row-level security, auth; business writes through SECURITY DEFINER RPCs.

## Commands

| Command | What it does |
|---|---|
| `npm run dev` | Development server |
| `npm run build` | Production build |
| `npm run lint` | ESLint |
| `npm run test:unit` | Unit tests (`tests/unit`) |
| `npm run test:e2e` | Playwright end-to-end tests (`tests/e2e`) |
| `npm run preflight` | Read-only environment checks before a deploy |

Security contracts for the database are SQL files in `tests/security/`, run against a local Supabase database rebuilt
from the migrations.

Environment variables: [`docs/deployment/ENVIRONMENT-VARIABLES.md`](./docs/deployment/ENVIRONMENT-VARIABLES.md).
