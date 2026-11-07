'use client'

import { ErrorNotice } from '@/components/shell/ErrorNotice'

// Boundary for the pages outside /app (login, mensalidade, plataforma, cadastro...).
export default function RootError({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  return <main className="flex flex-1 items-center px-4 py-10"><ErrorNotice digest={error.digest} retry={retry} homeHref="/" /></main>
}
