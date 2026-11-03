import Link from 'next/link'
import QRCode from 'qrcode'
import { Badge, Card } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { brl, CHARGE_STATE, dayLabel, monthLabel } from '@/lib/billing'
import { pixPayload } from '@/lib/pix'
import { signOut } from '@/app/app/actions'
import { CopyPix } from './CopyPix'

type Charge = { id: string; period: string; amount: string; due_on: string; block_on: string; txid: string; state: string; paid_on: string | null }
type Billing = { receiver: { key: string; name: string; city: string } | null; charges: Charge[] }

// Monthly fee of the company (03/11/2026): the administrator pays by Pix here; it opens even while the company is blocked.
// The other users only see that the fee is open. The platform owner confirms the payment and the access opens again.
export default async function FeePage() {
  const { supabase, organization, membership, billing } = await requireAppContext({ allowBillingBlocked: true })
  const blocked = billing?.blocked === true
  const isAdmin = membership.role === 'admin'
  const { data } = isAdmin ? await supabase.rpc('my_billing', { p_org: organization.id }) : { data: null }
  const b = (data ?? { receiver: null, charges: [] }) as Billing
  const open = [...b.charges].reverse().find(c => c.state !== 'paid')
  let code: string | null = null, qr: string | null = null
  if (open && b.receiver) {
    try {
      code = pixPayload({ ...b.receiver, amount: open.amount, txid: open.txid })
      qr = await QRCode.toDataURL(code, { margin: 1, width: 240 })
    } catch { code = null }
  }

  return (
    <main className="min-h-screen bg-canvas px-4 py-8">
      <Card className="mx-auto max-w-3xl p-6 sm:p-8">
        <p className="text-xs font-semibold uppercase tracking-[.2em] text-brand">{organization.name}</p>
        <h1 className="mt-1 text-2xl font-semibold text-ink">{blocked ? 'Acesso suspenso' : 'Mensalidade'}</h1>
        {blocked && <p className="mt-2 rounded-lg bg-[#FDE2E1] px-3 py-2 text-sm text-[#991B1B]">A mensalidade do Corban está em aberto e o acesso da empresa foi suspenso. Nenhum dado foi apagado. O acesso volta assim que o pagamento for confirmado.</p>}

        {!isAdmin ? (
          <p className="mt-5 rounded-lg bg-surface-muted px-3 py-2 text-sm text-ink-soft">{blocked ? 'Procure o administrador da empresa para regularizar a mensalidade.' : 'A mensalidade é paga pelo administrador da empresa.'}</p>
        ) : !open ? (
          <p className="mt-5 text-sm text-muted">Nenhuma mensalidade em aberto.</p>
        ) : (
          <div className="mt-5 grid gap-6 sm:grid-cols-[1fr_240px]">
            <div>
              <p className="text-sm text-muted">Mensalidade {monthLabel(open.period)}</p>
              <p className="mt-1 text-3xl font-semibold text-ink">{brl(open.amount)}</p>
              <p className="mt-1 text-sm text-muted">Vencimento {dayLabel(open.due_on)} · <Badge tone={(CHARGE_STATE[open.state] ?? ['', 'neutral'])[1]}>{(CHARGE_STATE[open.state] ?? [open.state])[0]}</Badge></p>
              {code ? <>
                <p className="mt-4 text-sm text-ink-soft">Recebedor: {b.receiver?.name} · {b.receiver?.city}</p>
                <CopyPix code={code} />
                <p className="mt-2 text-xs text-muted">Pague pelo app do seu banco com o QR Code ou o código. A confirmação é feita pela Corban e o acesso é liberado em seguida.</p>
              </> : <p className="mt-4 text-sm text-muted">O Pix para pagamento ainda não foi configurado. Fale com a Corban.</p>}
            </div>
            {/* eslint-disable-next-line @next/next/no-img-element -- data URL generated on the server */}
            {qr && <img src={qr} alt="QR Code Pix da mensalidade" width={240} height={240} className="rounded-[12px] border border-line" />}
          </div>
        )}

        {isAdmin && b.charges.length > 0 && <section className="mt-8">
          <h2 className="text-sm font-semibold text-ink">Histórico</h2>
          <ul className="mt-2 divide-y divide-line text-sm">{b.charges.map(c => <li key={c.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2">
            <span className="w-20 text-ink">{monthLabel(c.period)}</span><span className="text-ink-soft">{brl(c.amount)}</span><span className="text-muted">venc. {dayLabel(c.due_on)}</span>
            <Badge tone={(CHARGE_STATE[c.state] ?? ['', 'neutral'])[1]}>{c.paid_on ? `Paga em ${dayLabel(c.paid_on)}` : (CHARGE_STATE[c.state] ?? [c.state])[0]}</Badge>
          </li>)}</ul>
        </section>}

        <div className="mt-6 flex gap-4 text-sm">
          {!blocked && <Link href="/app" className="text-brand underline">Voltar ao sistema</Link>}
          <form action={signOut}><button className="text-muted underline hover:text-ink">Sair</button></form>
        </div>
      </Card>
    </main>
  )
}
