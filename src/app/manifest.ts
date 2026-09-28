import type { MetadataRoute } from 'next'

// Installable web app: "Adicionar à tela inicial" opens Corban full screen with its own icon (no app store).
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: 'Corban',
    short_name: 'Corban',
    description: 'Gestão para correspondentes bancários',
    lang: 'pt-BR',
    start_url: '/app/hoje',
    scope: '/',
    display: 'standalone',
    orientation: 'portrait',
    background_color: '#f6f5f1',
    theme_color: '#0e5e5a',
    icons: [
      { src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  }
}
