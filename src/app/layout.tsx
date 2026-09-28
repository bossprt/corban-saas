import './globals.css'
import type { Metadata, Viewport } from 'next'
import { IBM_Plex_Mono, IBM_Plex_Sans } from 'next/font/google'

const plexSans = IBM_Plex_Sans({ subsets: ['latin'], weight: ['400', '500', '600', '700'], variable: '--font-plex-sans', display: 'swap' })
const plexMono = IBM_Plex_Mono({ subsets: ['latin'], weight: ['400', '500'], variable: '--font-plex-mono', display: 'swap' })

export const metadata: Metadata = {
  title: 'Corban',
  description: 'Gestão para correspondentes bancários',
  applicationName: 'Corban',
  // iPhone: "Adicionar à Tela de Início" opens full screen with the Corban icon.
  appleWebApp: { capable: true, title: 'Corban', statusBarStyle: 'default' },
  icons: { icon: [{ url: '/icon-192.png', sizes: '192x192', type: 'image/png' }], apple: '/apple-touch-icon.png' },
}

export const viewport: Viewport = { themeColor: '#0e5e5a' }

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR" className={`${plexSans.variable} ${plexMono.variable}`}>
      <body className="flex min-h-screen flex-col bg-canvas text-ink antialiased">{children}</body>
    </html>
  )
}
