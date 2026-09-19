import { NextResponse } from 'next/server'
import { authorizeWorkerRequest } from '@/lib/integrations/worker'
import { dispatchOnce } from '@/lib/integrations/worker.server'

// One bounded dispatch pass. NOT scheduled anywhere: deployment decides who calls it (cron / queue / operator).
// Disabled (503) until INTEGRATION_WORKER_SECRET is configured; the response carries counts only, never payloads.
export const dynamic = 'force-dynamic'

export async function POST(request: Request) {
  const auth = authorizeWorkerRequest(request.headers.get('authorization'), process.env.INTEGRATION_WORKER_SECRET)
  if (auth === 'disabled') return NextResponse.json({ error: 'dispatch_disabled' }, { status: 503 })
  if (auth === 'forbidden') return NextResponse.json({ error: 'forbidden' }, { status: 403 })
  try {
    const { runs, ...counts } = await dispatchOnce({ limit: 10 })
    return NextResponse.json({ ok: true, ...counts, runs: runs.length })
  } catch {
    return NextResponse.json({ error: 'dispatch_failed' }, { status: 500 })
  }
}
