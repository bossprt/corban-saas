'use client'

// Last-resort boundary. The raw error text is never shown: in production Next.js hides it anyway, and in development it may contain internals.
export default function AppError({ error, reset }: { error: Error & { digest?: string }, reset: () => void }) {
  return <section role="alert" className="mx-auto max-w-xl rounded-2xl border border-amber-500/30 bg-amber-500/5 p-6">
    <h1 className="text-xl font-semibold text-amber-100">Algo não funcionou</h1>
    <p className="mt-2 text-sm text-slate-300">Não foi possível concluir. Seus dados não foram alterados por esta tela. Tente de novo; se continuar, avise o supervisor e informe a referência abaixo.</p>
    {error.digest && <p className="mt-2 text-xs text-slate-500">Referência: {error.digest}</p>}
    <button onClick={reset} className="mt-5 rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-950">Tentar novamente</button>
  </section>
}
