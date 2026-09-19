'use server'

import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { RepositoryError } from '@/lib/integrations/repository'
import { createWorkerRepository, dispatchOnce } from '@/lib/integrations/worker.server'
import { classifyRunActionError } from '@/lib/integrations/view-state'

// Governed boundary for the /app/integracoes buttons. The browser never receives the service role: these run on the server, resolve the
// caller from the session, pass THEIR user id as the actor, and the database functions re-check membership + role on the run's own
// tenant. There is no UPDATE on integration_runs anywhere in this file. Failures are classified and shown, never swallowed.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const back = (q: string): never => redirect(`/app/integracoes?${q}`)

async function ctx(minRole: 'supervisor' | 'manager', formData: FormData) {
  const { supabase, membership, organization, user } = await requireAppContext()
  const runId = String(formData.get('run_id') ?? '')
  if (!UUID.test(runId)) return back('erro=run_invalid')
  if (!atLeast(membership.role, minRole)) return back('erro=forbidden')
  // The run must be visible to the caller under RLS (supervisor+) inside the ACTIVE organization: tenant comes from the resource.
  const { data: run } = await supabase.from('integration_runs').select('id,organization_id').eq('id', runId).maybeSingle()
  if (!run || run.organization_id !== organization.id) return back('erro=run_not_found')
  return { runId, organizationId: organization.id as string, userId: user.id }
}

// "Nova tentativa": the SAME run. The worker claim decides (backoff, attempts, lease); this only asks for one governed pass on that run.
export async function retryRun(formData: FormData) {
  const c = await ctx('supervisor', formData)
  let outcome = 'ok=retry'
  try {
    const s = await dispatchOnce({ limit: 1, onlyRunId: c.runId })
    if (s.examined === 0) outcome = 'ok=retry_not_due'
  } catch (e) { outcome = `erro=${classifyRunActionError(e instanceof RepositoryError ? e.code : null)}` }
  revalidatePath('/app/integracoes')
  back(outcome)
}

// Cancel a run that is not terminal. manager+ is enforced again inside cancel_integration_run.
export async function cancelRun(formData: FormData) {
  const c = await ctx('manager', formData)
  let outcome = 'ok=cancelled'
  try { await createWorkerRepository().cancel({ organizationId: c.organizationId, runId: c.runId, actorUserId: c.userId }) }
  catch (e) { outcome = `erro=${classifyRunActionError(e instanceof RepositoryError ? e.code : null)}` }
  revalidatePath('/app/integracoes')
  back(outcome)
}

// "Nova execução": a NEW run linked to the terminal parent, with a mandatory human reason. The parent is never modified.
export async function reexecuteRun(formData: FormData) {
  const c = await ctx('manager', formData)
  const reason = String(formData.get('reason') ?? '').trim()
  if (reason.length < 10 || reason.length > 500) return back('erro=reason_invalid')
  let outcome = 'ok=reexecuted'
  try { await createWorkerRepository().reexecute({ organizationId: c.organizationId, parentRunId: c.runId, actorUserId: c.userId, reason, correlationId: `ui-${c.runId.slice(0, 8)}` }) }
  catch (e) { outcome = `erro=${classifyRunActionError(e instanceof RepositoryError ? e.code : null)}` }
  revalidatePath('/app/integracoes')
  back(outcome)
}
