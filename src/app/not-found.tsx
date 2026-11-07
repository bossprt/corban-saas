import Link from 'next/link'

// Any address that does not exist, in the whole site (and notFound() calls without a closer not-found page).
export default function NotFound() {
  return (
    <main className="flex flex-1 items-center px-4 py-10">
      <section className="mx-auto w-full max-w-xl rounded-2xl border border-line bg-surface p-6">
        <p className="text-sm font-semibold text-brand">Erro 404</p>
        <h1 className="mt-1 text-xl font-semibold text-ink">Página não encontrada</h1>
        <p className="mt-2 text-sm text-ink-soft">O endereço pode estar errado ou a página pode ter sido removida.</p>
        <Link href="/app" className="mt-5 inline-flex h-10 items-center rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong">Voltar ao início</Link>
      </section>
    </main>
  )
}
