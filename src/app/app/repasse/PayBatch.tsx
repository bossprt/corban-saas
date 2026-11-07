'use client'

import { Fragment, useEffect, useRef, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import QRCode from 'qrcode'
import { Check, ChevronLeft, ChevronRight, Copy, Download, QrCode, X } from 'lucide-react'
import { pixCopyPaste } from '@/lib/pix/brcode'
import type { PayLine } from '@/lib/payout/pay-list'
import { markAll } from '@/lib/payout/pay-safety'
import { PIX_TYPE_LABEL, formatTaxId } from '@/lib/sellers'
import { brlText } from '@/lib/receipts/format'
import { loadPayPreview, type PayBatchResult } from './actions'
import { PayoutBreakdown } from './PayoutBreakdown'
import type { Breakdown } from '@/lib/payout/batches'
import { sameAmount } from '@/lib/payout/pay-safety'
import { BankAccountSelect } from '@/components/BankAccountSelect'
import type { BankOption } from '@/lib/finBankAccounts'

// Cents as BigInt: money is never added as a float.
const cents = (amount: string) => BigInt(amount.replace('.', ''))
const fromCents = (c: bigint) => `${c / BigInt(100)}.${String(c % BigInt(100)).padStart(2, '0')}`
const tedText = (l: PayLine) => `Banco ${l.bankCode ?? ''}${l.bankName ? ` ${l.bankName}` : ''} · Ag. ${l.branch ?? ''} · Conta ${l.accountNumber ?? ''}${l.accountDigit ? `-${l.accountDigit}` : ''}`
// Who receives the money: the favorecido when there is one, else the seller.
const receiver = (l: PayLine) => l.holderName || l.name
const codeOf = (l: PayLine) => l.method === 'pix' && l.pixKey ? pixCopyPaste({ keyType: l.pixType, key: l.pixKey, amount: l.amount, name: receiver(l), city: l.city }) : null

function CopyButton({ text, label }: { text: string; label: string }) {
  const [done, setDone] = useState(false)
  return (
    <button type="button" aria-label={label} title={label} onClick={() => { void navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 1500) }}
      className="ml-1 inline-flex size-7 items-center justify-center rounded-md text-muted hover:bg-surface-muted hover:text-ink">
      {done ? <Check size={14} aria-hidden /> : <Copy size={14} aria-hidden />}
    </button>
  )
}

// Pay several sellers (owner request 06/10/2026): the list with the exact amounts and where to pay (PIX QR Code with the
// amount, copia e cola, or the TED data); the owner pays in the bank and then confirms the ones paid. Nothing is
// recorded until "Confirmar"; an amount that changed meanwhile is refused, so the record always matches the bank.
export function PayBatch({ lines, action, today, banks = [], suggestedBank = '' }: { lines: PayLine[]; action: (f: FormData) => Promise<PayBatchResult>; today: string; banks?: BankOption[]; suggestedBank?: string }) {
  const router = useRouter()
  // Nobody is ticked when the list opens (audit 06/11/2026): forgetting to untick recorded payments never made.
  const [checked, setChecked] = useState<Set<string>>(() => new Set())
  // People "Marcar todos" left out because they have no PIX key or bank account.
  const [skipped, setSkipped] = useState<string[]>([])
  // Confirmation step: the first "Confirmar" shows how many and how much; only "Sim, registrar" sends.
  const [confirming, setConfirming] = useState(false)
  const [qr, setQr] = useState<number | null>(null)
  // The QR Code sequence is fixed when it opens: only the checked sellers (owner, 13/10/2026: with 5 of 6 checked it
  // showed all 6, so an unchecked seller could be paid by mistake).
  const [qrList, setQrList] = useState<string[]>([])
  const [drawn, setDrawn] = useState<{ code: string; svg: string } | null>(null)
  const [result, setResult] = useState<PayBatchResult | null>(null)
  const [pending, start] = useTransition()
  // "ver contratos" (owner, 06/11/2026): the contracts and entries of each amount, read before paying.
  const [open, setOpen] = useState<Set<string>>(() => new Set())
  const [previews, setPreviews] = useState<Record<string, { data?: Breakdown & { total: string }; error?: string }>>({})
  const togglePreview = (id: string) => {
    setOpen(s => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })
    if (!previews[id]) void loadPayPreview(id).then(r => setPreviews(p => ({ ...p, [id]: r })))
  }
  const dialog = useRef<HTMLDialogElement>(null)
  const pixLines = qrList.map(id => lines.find(l => l.account === id)).filter((l): l is PayLine => !!l && !!codeOf(l))
  const current = qr === null ? null : pixLines[qr]
  const currentCode = current ? codeOf(current) : null

  const svg = drawn && drawn.code === currentCode ? drawn.svg : ''
  useEffect(() => {
    if (!currentCode) return
    let live = true
    void QRCode.toString(currentCode, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' }).then(s => { if (live) setDrawn({ code: currentCode, svg: s }) })
    return () => { live = false }
  }, [currentCode])
  useEffect(() => { if (qr === null) dialog.current?.close(); else if (!dialog.current?.open) dialog.current?.showModal() }, [qr])

  const chosen = lines.filter(l => checked.has(l.account))
  const totalAll = fromCents(lines.reduce((a, l) => a + cents(l.amount), BigInt(0)))
  const totalChosen = fromCents(chosen.reduce((a, l) => a + cents(l.amount), BigInt(0)))
  const chosenPix = chosen.filter(l => codeOf(l))
  const openQr = (l?: PayLine) => {
    const ids = chosenPix.map(x => x.account)
    if (l && !ids.includes(l.account)) { setQrList([l.account]); setQr(0); return }
    setQrList(ids); setQr(l ? ids.indexOf(l.account) : 0)
  }
  const toggle = (id: string) => { setConfirming(false); setChecked(s => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n }) }
  const tickAll = () => { const r = markAll(lines); setConfirming(false); setChecked(r.checked); setSkipped(r.skipped.map(l => l.name)) }
  const untickAll = () => { setConfirming(false); setChecked(new Set()); setSkipped([]) }

  const submit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (!confirming) { setResult(null); setConfirming(true); return }
    const data = new FormData(e.currentTarget)
    setResult(null)
    start(async () => {
      const r = await action(data)
      setResult(r)
      setConfirming(false)
      if (!r.error && r.ok) { setChecked(new Set()); setSkipped([]); router.refresh() }
    })
  }

  if (!lines.length) return <p className="px-5 py-4 text-sm text-ink-soft">Nenhum vendedor com valor liberado para pagar agora.</p>
  const th = 'px-3 py-2 font-medium'
  return (
    <form method="post" onSubmit={submit}>
      <div className="flex flex-wrap items-center justify-between gap-3 px-5 pb-3 text-sm">
        <span className="text-ink-soft">{lines.length} a pagar · <strong className="text-ink">{brlText(totalAll)}</strong> · marcados {chosen.length} · <strong className="text-ink">{brlText(totalChosen)}</strong></span>
        <span className="flex flex-wrap gap-2">
          <button type="button" onClick={tickAll} className="h-9 rounded-none border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted">Marcar todos</button>
          <button type="button" onClick={untickAll} className="h-9 rounded-none border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted">Desmarcar</button>
          {lines.some(l => codeOf(l)) && <button type="button" onClick={() => openQr()} disabled={!chosenPix.length} className="inline-flex h-9 items-center gap-1.5 rounded-none border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted disabled:opacity-50"><QrCode size={15} aria-hidden />Pagar marcados com QR Code ({chosenPix.length})</button>}
          <a href="/api/repasse/pagamentos" download className="inline-flex h-9 items-center gap-1.5 rounded-none border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted"><Download size={15} aria-hidden />Baixar Excel</a>
        </span>
      </div>
      {!!skipped.length && <p role="status" className="mx-5 mb-3 rounded-none bg-[#FEF2F2] px-3 py-2 text-xs text-[#991B1B]">Não marcados por falta de chave PIX ou conta no cadastro: {skipped.join(', ')}.</p>}
      <div className="overflow-x-auto">
        <table className="w-full min-w-[760px] text-left text-[13px]">
          <thead className="border-y border-line bg-surface-muted text-xs text-muted"><tr>
            <th className="w-10 py-2 pl-5 pr-1"><span className="sr-only">Pagar</span></th><th className={th}>Vendedor</th><th className={`${th} text-right`}>Valor</th><th className={th}>Como pagar</th>
          </tr></thead>
          <tbody>
            {lines.map(l => {
              const code = codeOf(l)
              return (
                <Fragment key={l.account}>
                <tr className="border-t border-line align-top">
                  <td className="py-2.5 pl-5 pr-1">
                    <input type="checkbox" name="account" value={l.account} checked={checked.has(l.account)} onChange={() => toggle(l.account)} disabled={!l.method}
                      aria-label={`Pagar ${l.name}`} title={l.method ? undefined : 'Sem chave PIX nem conta no cadastro'} className="accent-[var(--brand)] disabled:opacity-40" />
                    <input type="hidden" name={`amount_${l.account}`} value={l.amount} /><input type="hidden" name={`name_${l.account}`} value={l.name} />
                  </td>
                  <td className="px-3 py-2.5"><Link href={`/app/repasse/${l.account}`} className="font-medium text-ink hover:underline">{l.name}</Link>
                    <button type="button" onClick={() => togglePreview(l.account)} aria-expanded={open.has(l.account)} className="block text-xs font-medium text-brand hover:underline">{open.has(l.account) ? 'fechar contratos' : 'ver contratos'}</button></td>
                  <td className="num whitespace-nowrap px-3 py-2.5 text-right font-semibold text-ink">{brlText(l.amount)}</td>
                  <td className="px-3 py-2.5">
                    {!l.method ? <span className="rounded-md bg-[#FEF2F2] px-2 py-0.5 text-xs text-[#991B1B]">Sem chave PIX nem conta no cadastro</span>
                      : l.method === 'pix' ? <>
                        <span>PIX {PIX_TYPE_LABEL[l.pixType ?? ''] ?? ''}: <span className="font-mono">{l.pixKey}</span></span>{l.pixKey && <CopyButton text={l.pixKey} label="Copiar chave PIX" />}
                        {code ? <button type="button" onClick={() => openQr(l)} className="ml-1 inline-flex h-7 items-center gap-1 rounded-md px-2 text-xs text-brand hover:bg-surface-muted"><QrCode size={14} aria-hidden />QR Code</button>
                          : <span className="ml-1 text-xs text-[#92400E]">chave fora do padrão: confira o cadastro</span>}
                      </> : <><span>TED {tedText(l)}</span><CopyButton text={tedText(l)} label="Copiar dados da conta" /></>}
                    {l.holderName && <span className="block text-xs text-[#92400E]">Favorecido: {l.holderName}{l.holderDocument ? ` · ${formatTaxId(l.holderDocument)}` : ''}</span>}
                  </td>
                </tr>
                {open.has(l.account) && (
                  <tr className="bg-surface-muted/40">
                    <td colSpan={4} className="px-0 py-0">
                      {!previews[l.account] ? <p className="px-5 py-3 text-xs text-muted">Carregando contratos...</p>
                        : previews[l.account].error || !previews[l.account].data ? <p className="px-5 py-3 text-xs text-[#991B1B]">{previews[l.account].error ?? 'Não foi possível carregar os contratos.'}</p>
                        : <>
                          {!sameAmount(previews[l.account].data!.total, l.amount) && <p className="px-5 pt-3 text-xs font-semibold text-[#991B1B]">O valor mudou para {brlText(previews[l.account].data!.total)} desde que a lista abriu. Atualize a página antes de pagar.</p>}
                          <PayoutBreakdown b={previews[l.account].data!} total={previews[l.account].data!.total} empty="Sem contratos: o valor vem só de outros lançamentos." />
                        </>}
                    </td>
                  </tr>
                )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      </div>
      <div className="grid gap-3 border-t border-line bg-surface-muted/50 px-5 py-4">
        <p className="text-xs text-ink-soft">Faça os pagamentos no banco e marque só os que você pagou. Nada é registrado antes de confirmar, e é tudo ou nada: se um valor mudou, ninguém é registrado.</p>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <span className="flex flex-wrap items-end gap-3">
            <label className="text-[13px] font-medium text-ink-soft">Pago em<input type="date" name="paid_on" required defaultValue={today} max={today} className="field mt-1.5" /></label>
            <label className="text-[13px] font-medium text-ink-soft">Comprovante <span className="font-normal text-muted">opcional</span><input name="reference" maxLength={120} placeholder="PIX 06/10" className="field mt-1.5 w-48" /></label>
            <BankAccountSelect banks={banks} suggested={suggestedBank} label="Conta que pagou" />
          </span>
          {!confirming && (
            <button type="submit" disabled={pending || !chosen.length} className="inline-flex h-10 items-center gap-1.5 rounded-none bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">
              <Check size={16} aria-hidden />{`Confirmar ${chosen.length} pago(s) · ${brlText(totalChosen)}`}
            </button>
          )}
        </div>
        {confirming && (
          <div role="alertdialog" aria-label="Confirmar pagamentos" className="flex flex-wrap items-center justify-between gap-3 rounded-none border border-brand/40 bg-surface px-3 py-2">
            <span className="text-sm text-ink">Registrar <strong>{chosen.length}</strong> pagamento(s), total <strong className="num">{brlText(totalChosen)}</strong>? Confira se pagou cada um no banco.</span>
            <span className="flex gap-2">
              <button type="button" onClick={() => setConfirming(false)} disabled={pending} className="h-9 rounded-none border border-line-strong bg-surface px-3 text-sm hover:bg-surface-muted">Voltar</button>
              <button type="submit" disabled={pending || !chosen.length} aria-busy={pending} className="inline-flex h-9 items-center gap-1.5 rounded-none bg-brand px-3 text-sm font-semibold text-white hover:bg-brand-strong disabled:opacity-50">
                <Check size={16} aria-hidden />{pending ? 'Registrando...' : 'Sim, registrar'}
              </button>
            </span>
          </div>
        )}
        {result && (
          <div role="status" className={`rounded-none border px-3 py-2 text-sm ${result.error || result.failed.length ? 'border-[#FCD34D] bg-[#FFFBEB] text-[#92400E]' : 'border-[#86EFAC] bg-[#F0FDF4] text-[#166534]'}`}>
            {result.error ?? `${result.ok} pagamento(s) registrado(s) · ${brlText(result.total)}.${result.failed.length ? ` ${result.failed.length} não registrado(s):` : ''}`}
            {result.batchId && <> <Link href={`/app/repasse/lotes/${result.batchId}`} className="font-semibold underline">Ver o lote</Link></>}
            {!!result.failed.length && <ul className="mt-1 list-disc pl-5">{result.failed.map(x => <li key={x.account}>{x.name}: {x.reason}</li>)}</ul>}
          </div>
        )}
      </div>

      <dialog ref={dialog} onClose={() => setQr(null)} aria-label="Pagar com QR Code" className="m-auto w-[min(92vw,420px)] rounded-none border border-line bg-surface p-0 text-ink backdrop:bg-black/50">
        {current && (
          <div className="grid gap-3 p-5 text-center">
            <div className="flex items-center justify-between text-left">
              <span className="text-xs text-muted">{(qr ?? 0) + 1} de {pixLines.length}</span>
              <button type="button" onClick={() => setQr(null)} aria-label="Fechar" className="inline-flex size-8 items-center justify-center rounded-md text-muted hover:bg-surface-muted"><X size={16} aria-hidden /></button>
            </div>
            <div className="text-sm text-ink-soft">{current.name}</div>
            <div className="num text-2xl font-semibold">{brlText(current.amount)}</div>
            <div className="mx-auto w-60 rounded-none bg-white p-2" dangerouslySetInnerHTML={{ __html: svg }} />
            <div className="text-xs text-ink-soft">Recebe: <strong className="text-ink">{receiver(current)}</strong> · PIX {PIX_TYPE_LABEL[current.pixType ?? ''] ?? ''} <span className="font-mono">{current.pixKey}</span></div>
            <p className="rounded-none bg-[#FFFBEB] px-3 py-2 text-left text-xs text-[#92400E]">No app do banco, confira se o nome de quem recebe é <strong>{receiver(current)}</strong> antes de confirmar.</p>
            {currentCode && <button type="button" onClick={() => void navigator.clipboard.writeText(currentCode)} className="mx-auto inline-flex h-9 items-center gap-1.5 rounded-none border border-line-strong px-3 text-sm hover:bg-surface-muted"><Copy size={15} aria-hidden />Copiar PIX copia e cola</button>}
            <div className="flex justify-between">
              <button type="button" disabled={!qr} onClick={() => setQr(q => (q ?? 1) - 1)} className="inline-flex h-9 items-center gap-1 rounded-none px-3 text-sm hover:bg-surface-muted disabled:opacity-40"><ChevronLeft size={16} aria-hidden />Anterior</button>
              <button type="button" disabled={(qr ?? 0) >= pixLines.length - 1} onClick={() => setQr(q => (q ?? 0) + 1)} className="inline-flex h-9 items-center gap-1 rounded-none px-3 text-sm hover:bg-surface-muted disabled:opacity-40">Próximo<ChevronRight size={16} aria-hidden /></button>
            </div>
          </div>
        )}
      </dialog>
    </form>
  )
}
