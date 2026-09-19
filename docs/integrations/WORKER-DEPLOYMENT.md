# Integration worker — deployment notes

Nothing here is scheduled or enabled by the repository.

## Pieces
- `src/lib/integrations/worker.ts` — pure core: `runDispatchCycle` (bounded: at most 25 runs per pass, no loop, no timer), `resolveProvider`, `authorizeWorkerRequest`.
- `src/lib/integrations/worker.server.ts` — `server-only` wiring with the service role and `SupabaseRunRepository`. Importing it from a Client Component fails the build.
- `POST /api/integrations/dispatch` — one pass. Returns counts only.
- UI actions (`/app/integracoes`): `retryRun` (same run), `cancelRun`, `reexecuteRun` (new run linked to a terminal parent).

## Enabling (a human decision)
1. Set `INTEGRATION_WORKER_SECRET` (24+ characters) in the server environment. Until then the route answers `503 dispatch_disabled`.
2. Choose ONE caller: an operator, a cron, or a queue. It must send `Authorization: Bearer <secret>`. Two callers are safe (the database `claim` arbitrates with a lease and a fencing token) but wasteful.
3. Local/fake provider: only outside production and only with `CORBAN_ALLOW_LOCAL_PROVIDERS=1`. In production no provider is resolvable today (2Tech waits for a real file; Bevicred is deferred).

## Rules for request payloads
The persisted request (`integration_runs.metadata.request`) is redacted before it is stored, and the worker executes the STORED value. Requests must therefore carry references (ids) that the provider adapter resolves at call time, never personal data or credentials.

## Retry vs re-execution
- **Nova tentativa** continues the same run; the database still enforces backoff, attempts and lease.
- **Nova execução** creates a new run pointing at a terminal parent (failed terminally or cancelled) with a mandatory reason. A succeeded run is never re-executed.
