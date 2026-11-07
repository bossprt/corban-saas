'use client'

import Link from 'next/link'

// Error boundary content in the system colours. The raw error text is never shown: in production Next.js hides it anyway, and in development it may contain internals.
// The error can happen after something was saved, so it never promises that nothing changed.
export function ErrorNotice({ digest, retry, homeHref = '/app' }: { digest?: string; retry: () => void; homeHref?: string }) {
  return (
    <section role="alert" className="mx-auto w-full max-w-xl rounded-2xl border border-line bg-surface p-6">
      <h1 className="text-xl font-semibold text-ink">Algo não funcionou</h1>
      <p className="mt-2 text-sm text-ink-soft">Não conseguimos confirmar se a ação foi concluída. Confira antes de repetir. Se continuar, avise o supervisor e informe a referência abaixo.</p>
      {digest && <p className="mt-2 text-xs text-muted">Referência: {digest}</p>}
      <div className="mt-5 flex flex-wrap gap-2">
        <button type="button" onClick={retry} className="inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Tentar novamente</button>
        <Link href={homeHref} className="inline-flex h-10 items-center rounded-[10px] border border-line bg-surface px-4 text-sm font-medium text-ink hover:bg-surface-muted">Voltar ao início</Link>
      </div>
    </section>
  )
}
