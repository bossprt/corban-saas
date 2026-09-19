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

## Scheduler readiness (nothing below is configured)
The domain never depends on a scheduler: anything that can send `POST /api/integrations/dispatch` with `Authorization: Bearer <secret>` works (Vercel Cron, n8n, GitHub Actions, a queue consumer, an operator with curl). Moving between them changes no domain code.

| Parameter | Value in code | Why |
|---|---|---|
| Recommended frequency | every 1 minute (5 minutes is enough for a pilot) | retries back off by 30 s, 60 s, 120 s…; a shorter period only adds empty passes |
| Runs per pass | at most 10 from the route (hard cap 25) | bounded work per invocation |
| Provider timeout | 20 s | must be shorter than the lease |
| Lease | 60 s | a killed invocation is recovered by takeover after 60 s and the lost attempt is kept in the history |
| Pass budget | 45 s, route `maxDuration` 60 s | no new run starts when a provider timeout no longer fits; the rest waits for the next pass |
| Concurrency | any number of overlapping callers | `claim` serializes per run (row lock + lease + fencing token); a run in flight is `in_progress` for everyone else |
| Backpressure | 25-run ceiling per pass, oldest-eligible first | a backlog drains over passes; runs the worker cannot execute (unregistered / deferred / local-in-production adapters) are filtered out in SQL and never occupy a slot |
| Retry | database-governed (backoff, max attempts, terminal errors) | the caller never decides |
| Observability | one sanitized JSON event per step (`correlationId`, `runId`, provider, adapter, capability, attempt, duration, outcome, error code) | metrics derivable with `computeRunMetrics` |

Not activated: no cron entry, no `INTEGRATION_WORKER_SECRET`, no external service, no provider credentials.
