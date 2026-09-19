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

## Activation runbook (exact order; nothing here was executed)
1. Confirm the database has `20260923_worker_dispatch_hardening_v1` (it is LIVE). The code also tolerates the older 2-argument dispatch function, but scoped dispatch needs the new one.
2. Generate a random secret of 32+ characters outside the repository. Store it ONLY in the hosting provider's server-side environment as `INTEGRATION_WORKER_SECRET`. Never prefix it with `NEXT_PUBLIC_`, never put it in the repository, chat or logs.
3. Keep `CORBAN_ALLOW_LOCAL_PROVIDERS` unset in production. The fake provider then cannot run there, whatever else is set.
4. Deploy. Open `/app/integracoes` as a supervisor: "Prontidão do processamento" must show the secret as configured. It shows booleans only.
5. Smoke test from a trusted terminal (expects HTTP 200 and counts only; the first call processes nothing if the queue is empty):
   `curl -sS -X POST https://<host>/api/integrations/dispatch -H "Authorization: Bearer $INTEGRATION_WORKER_SECRET"`
   Without the header the answer must be 403; without the secret configured, 503.
6. Choose ONE scheduler and point it at that URL (every 1-5 minutes). Vercel Cron, n8n, GitHub Actions and a queue consumer are equivalent because the domain only sees the HTTP call. Give it the same header.
7. Watch the sanitized JSON events (`correlationId`, `runId`, provider, adapter, outcome). Nothing in them is secret.
8. To stop everything at once: remove the secret (the route answers 503) or pause the scheduler. Queued runs stay queued; nothing is lost.

Uptime monitors use `GET /api/health` (application + database reachability only). Provider or worker state is business readiness and is shown only to signed-in supervisors.

## Failure modes (behaviour proved by the worker hardening tests and SQL harnesses)
| Situation | What happens |
|---|---|
| Scheduler never calls | Runs stay queued/eligible; the operator sees them in `/app/integracoes`. Nothing is lost or duplicated. |
| Scheduler calls twice / two instances at once | `claim` serializes per run (row lock + lease + fencing token). One executes, the other sees `in_progress`. |
| HTTP request times out or the process is killed | The lease expires (60 s); the next pass takes the run over and the lost attempt is recorded as `lease_expired` in the immutable history. |
| Provider timeout | The run is failed as retryable with backoff; attempts are bounded; after the last attempt it is terminal and waits for a human (re-execution creates a NEW run). |
| Provider unavailable / hostile error text | Same as timeout; secret-looking messages are replaced by fixed markers so the run never gets stuck. |
| Database briefly unavailable | The pass answers 500 `dispatch_failed` (no details); the next pass continues from the persisted state. |
| Wrong secret / malformed header / empty | 403. Missing or short secret on the server: 503. No value is ever logged. |
| Backlog larger than one pass | At most 10 runs per call (hard cap 25), oldest eligible first; the rest drains over the next passes. Runs of adapters the worker cannot execute never occupy a slot. |

## Recommended cadence (technical estimate, NOT a guarantee and NOT configured)
Facts from the code: one pass handles at most 10 runs from the route (hard cap 25), strictly one after another; provider timeout 20 s; lease 60 s; pass budget 45 s (no new run starts unless a provider timeout still fits); route `maxDuration` 60 s; retry backoff is database-governed (30 s, 60 s, 120 s...).
- **Every 1 minute** is the recommended start. Worst case (every provider call takes the full 20 s) a pass completes only about 2 runs before the budget stops it, so throughput is roughly 2 runs/minute; with fast providers a pass can drain up to 10 runs/minute. The 25-run ceiling is a safety cap, not a throughput target.
- **Every 5 minutes** is enough for a low-volume pilot (few runs a day) and costs less; the price is up to 5 minutes of added latency for a retry that just became due.
- **Faster than 1 minute** gains little: retries back off by at least 30 s and overlapping callers are safe but only add empty passes.
- Two callers at once are safe (lease + fencing token) but wasteful. If a backlog persists, shorten the interval before touching batch size or timeouts, and measure `computeRunMetrics` output first.
- Provider latency is the dominant factor. No real provider is homologated, so these numbers are unmeasured against real traffic; re-derive them at the first real integration.
