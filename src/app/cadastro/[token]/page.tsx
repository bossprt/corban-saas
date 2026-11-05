import type { Metadata } from 'next'
import { CheckCircle2 } from 'lucide-react'
import { Card } from '@/components/ui'
import { createClient } from '@/utils/supabase/server'
import { SellerForm } from '@/app/app/cadastros/vendedores/SellerForm'
import { submitSignup } from './actions'

export const metadata: Metadata = { title: 'Cadastro de vendedor', robots: { index: false, follow: false } }

// Seller registration link (owner approval 05/11/2026): opened without login from the link the company sent. It shows
// only the company and the seller group of the link; the form is the same seller form without the administrator's fields.
export default async function SignupPage({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<{ enviado?: string }> }) {
  const { token } = await params
  const { enviado } = await searchParams
  const valid = /^[A-Za-z0-9_-]{20,64}$/.test(token)
  const supabase = await createClient()
  const { data } = valid ? await supabase.rpc('seller_signup_link_info', { p_token: token }) : { data: null }
  const info = (data as { organization_name: string; group_name: string }[] | null)?.[0]

  return (
    <main className="min-h-screen bg-canvas px-4 py-8">
      <Card className="mx-auto max-w-4xl p-5 sm:p-8">
        {!info ? (
          <>
            <h1 className="text-xl font-semibold text-ink">Link indisponível</h1>
            <p className="mt-2 text-sm text-ink-soft">Este link de cadastro não existe ou foi desligado. Peça um novo link à empresa.</p>
          </>
        ) : enviado ? (
          <div className="flex gap-3">
            <CheckCircle2 size={28} aria-hidden className="shrink-0 text-[#15803D]" />
            <div>
              <h1 className="text-xl font-semibold text-ink">Cadastro enviado</h1>
              <p className="mt-2 text-sm text-ink-soft">A {info.organization_name} vai conferir seus dados e entrar em contato. Você já pode fechar esta página.</p>
            </div>
          </div>
        ) : (
          <>
            <p className="text-xs font-semibold uppercase tracking-[.2em] text-brand">{info.organization_name}</p>
            <h1 className="mt-1 text-2xl font-semibold text-ink">Cadastro de vendedor</h1>
            <p className="mb-6 mt-2 text-sm text-ink-soft">Tipo: <span className="rounded-md bg-[#E6F1FB] px-2 py-0.5 font-medium text-[#0C447C]">{info.group_name}</span></p>
            <SellerForm action={submitSignup.bind(null, token)} mode="public" groups={[]} branches={[]} canEdit canSeeBank />
          </>
        )}
      </Card>
    </main>
  )
}
