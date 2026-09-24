<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# CORBAN OS — AGENT BOOTSTRAP

Before changing architecture, schema, authorization, financial logic or domain behavior, read:

1. `/CORBAN-OS-PROJECT-CONTEXT-V2.md`
2. `/CORBAN-OS-MASTER-V2.md`
3. `/.ai/RULES.md`
4. `/.ai/DECISIONS.md`
5. `/.ai/CURRENT-TASK.md`
6. `/CORBAN-CURRENT-STATE.md` only as historical evidence to reconcile with code, Git and the live database.

V2 master is the conceptual source of truth. Live code, migrations and database are evidence of what is implemented. Never describe planned capability as implemented.

Tenant isolation is fail-closed. Never weaken RLS to make a feature work. Never use floating point for money. Financial history is immutable except explicit compensating/reversal records. AI suggestions do not publish financial truth without deterministic validation and required Human Gates.

Do not modify `main` directly. No destructive migration, production publication, secrets, significant spend or irreversible external action without Human Gate. End each execution cycle by updating CURRENT-TASK/CHANGELOG and architectural decisions when applicable.
