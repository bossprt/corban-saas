import './globals.css'
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Corban SaaS - Sistema para Correspondentes Bancários',
  description: 'Gestão multi-tenant para correspondentes bancários',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="pt-BR">
      <body className="bg-slate-950 text-slate-100 antialiased min-h-screen flex flex-col">
        {children}
      </body>
    </html>
  )
}
