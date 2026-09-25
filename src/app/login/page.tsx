import LoginForm from './LoginForm'

// An invitation e-mail link that failed verification lands here with ?erro=link (see /auth/confirm).
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ erro?: string }> }) {
  const sp = await searchParams
  return <LoginForm notice={sp.erro === 'link' ? 'Link de convite inválido ou expirado. Peça um novo convite ao administrador.' : undefined} />
}
