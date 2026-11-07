'use client'

import './globals.css'
import { ErrorNotice } from '@/components/shell/ErrorNotice'

// Replaces the root layout when the layout itself fails: it needs its own <html> and <body>.
export default function GlobalError({ error, retry }: { error: Error & { digest?: string }; retry: () => void }) {
  return (
    <html lang="pt-BR">
      <body className="flex min-h-screen flex-col bg-canvas text-ink antialiased">
        <title>Corban</title>
        <main className="flex flex-1 items-center px-4 py-10"><ErrorNotice digest={error.digest} retry={retry} homeHref="/" /></main>
      </body>
    </html>
  )
}
