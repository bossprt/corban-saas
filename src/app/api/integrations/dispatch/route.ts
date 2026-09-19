import { NextResponse } from 'next/server'
import { handleDispatchRequest } from '@/lib/integrations/worker'
import { dispatchOnce } from '@/lib/integrations/worker.server'

// One bounded dispatch pass. NOT scheduled anywhere: deployment decides who calls it (cron / queue / operator).
// Disabled (503) until INTEGRATION_WORKER_SECRET is configured; the response carries counts only, never payloads.
// It does not read the user session (the proxy exempts this path): the bearer secret is the only credential.
export const dynamic = 'force-dynamic'
// Platform limit for one invocation; the dispatch pass keeps its own budget below it (see dispatchOnce).
export const maxDuration = 60

export async function POST(request: Request) {
  const res = await handleDispatchRequest({
    authorization: request.headers.get('authorization'),
    secret: process.env.INTEGRATION_WORKER_SECRET,
    run: () => dispatchOnce({ limit: 10 }),
  })
  return NextResponse.json(res.body, { status: res.status })
}
