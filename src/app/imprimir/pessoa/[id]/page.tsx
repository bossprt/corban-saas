import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { isUuid } from '@/lib/team'
import type { AccountReport } from '@/lib/payout/batches'
import { PrintBar } from '../../PrintBar'
import { PRINT_CSS } from '../../sheets'
import { PersonSheet } from '../../PersonSheet'

const DATE = /^\d{4}-\d{2}-\d{2}$/
const monthStart = () => { const d = new Date(Date.now() - 3 * 3600_000).toISOString(); return `${d.slice(0, 8)}01` }
const today = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10)

// Report per person over a period (owner, 21/10/2026): every payment made to them, contract by contract, with the total.
// Finance, or the person themself (their own report).
export default async function PrintPersonReport({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ de?: string; ate?: string }> }) {
  const { id } = await params
  const sp = await searchParams
  if (!isUuid(id)) notFound()
  const from = DATE.test(sp.de ?? '') ? sp.de! : monthStart()
  const to = DATE.test(sp.ate ?? '') ? sp.ate! : today()
  const { supabase } = await requireAppContext()
  const { data, error } = await supabase.rpc('payout_account_report', { p_account: id, p_from: from, p_to: to })
  if (error || !data) notFound()
  const r = data as AccountReport

  return (
    <div className="sheets">
      <style>{PRINT_CSS}</style>
      <PrintBar back={`/app/repasse/${id}`}>
        <form className="flex flex-wrap items-center gap-2 text-sm">
          <label className="flex items-center gap-1.5">De<input type="date" name="de" defaultValue={from} className="field h-9" /></label>
          <label className="flex items-center gap-1.5">até<input type="date" name="ate" defaultValue={to} className="field h-9" /></label>
          <button className="inline-flex h-9 items-center rounded-[10px] border border-line bg-surface px-3 hover:bg-surface-muted">Ver período</button>
        </form>
      </PrintBar>

      <PersonSheet r={r} />
    </div>
  )
}
