'use client'

export default function AppError({ error, reset }: { error: Error & { digest?: string }, reset: () => void }) {
  return <section className="mx-auto max-w-xl rounded-2xl border border-red-500/20 bg-red-500/5 p-6">
    <h1 className="text-xl font-semibold text-red-200">Não foi possível concluir esta ação</h1>
    <p className="mt-2 text-sm text-slate-300">{error.message || 'O Corban OS bloqueou a operação para preservar a consistência dos dados.'}</p>
    {error.digest && <p className="mt-2 text-xs text-slate-500">Referência: {error.digest}</p>}
    <button onClick={reset} className="mt-5 rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-950">Tentar novamente</button>
  </section>
}
