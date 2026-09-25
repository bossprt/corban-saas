import Link from 'next/link'
import { AuthShell, authButton, authError, authLabel } from '@/components/shell/AuthShell'
import { requestPasswordReset } from './actions'

export default async function RecoverPasswordPage({ searchParams }: { searchParams: Promise<{ erro?: string; enviado?: string }> }) {
  const sp = await searchParams
  return (
    <AuthShell subtitle="Recuperar senha">
      {sp.enviado ? (
        <p role="status" className="text-sm text-ink">Se este e-mail tiver acesso ao Corban, você receberá em instantes um link para criar uma nova senha. Confira também a caixa de spam.</p>
      ) : (
        <form action={requestPasswordReset} className="space-y-5">
          <p className="text-sm text-ink-soft">Informe o e-mail do seu acesso. Enviaremos um link para criar uma nova senha.</p>
          <div>
            <label htmlFor="recover-email" className={authLabel}>E-mail</label>
            <input id="recover-email" name="email" type="email" autoComplete="email" required maxLength={254} className="field h-11" />
          </div>
          {sp.erro === 'email' && <p role="alert" className={authError}>Informe um e-mail válido.</p>}
          <button type="submit" className={authButton}>Enviar link</button>
        </form>
      )}
      <p className="mt-5 text-center text-[13px]"><Link href="/login" className="text-brand hover:text-brand-strong">Voltar ao login</Link></p>
    </AuthShell>
  )
}
