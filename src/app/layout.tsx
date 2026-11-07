import './globals.css'
import type { Metadata, Viewport } from 'next'
import { Archivo } from 'next/font/google'

// Variable Archivo with its width axis: wide titles and narrow labels come from the same family (identity "Boleto ipê").
const archivo = Archivo({ subsets: ['latin'], axes: ['wdth'], variable: '--font-archivo', display: 'swap' })

export const metadata: Metadata = {
  title: 'Corban',
  description: 'Gestão para correspondentes bancários',
  applicationName: 'Corban',
  // iPhone: "Adicionar à Tela de Início" opens full screen with the Corban icon.
  appleWebApp: { capable: true, title: 'Corban', statusBarStyle: 'default' },
  icons: { icon: [{ url: '/icon-192.png', sizes: '192x192', type: 'image/png' }], apple: '/apple-touch-icon.png' },
}

export const viewport: Viewport = { themeColor: '#ffffff' }

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pt-BR" className={archivo.variable}>
      <body className="flex min-h-screen flex-col bg-canvas text-ink antialiased">{children}</body>
    </html>
  )
}
