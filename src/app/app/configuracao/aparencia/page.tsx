import { Card, PageHeader } from '@/components/ui'
import { requireAppContext } from '@/lib/appContext'
import { DEFAULT_ACCENT, DEFAULT_BRAND, logoUrl, normalizeHex } from '@/lib/branding'
import { publicSupabaseEnv } from '@/lib/env'
import { saveBranding } from './actions'

const label = 'text-[13px] font-semibold text-ink-soft'

// The company's look: primary color, accent color and logo. Everyone in the company sees them; only the admin changes them.
export default async function BrandingPage() {
  const { organization, membership } = await requireAppContext()
  if (membership.role !== 'admin') {
    return <section><PageHeader title="Aparência" /><Card className="p-5 text-sm text-ink-soft">Somente o administrador da empresa muda as cores e o logo.</Card></section>
  }
  const org = organization as typeof organization & { brand_color?: string | null; accent_color?: string | null; logo_path?: string | null }
  const brand = normalizeHex(org.brand_color) ?? DEFAULT_BRAND
  const accent = normalizeHex(org.accent_color) ?? DEFAULT_ACCENT
  const logo = logoUrl(publicSupabaseEnv().url, organization.id, org.logo_path)

  return (
    <section>
      <PageHeader title="Aparência" description="Cores e logo que toda a equipe vê no sistema." />
      <Card className="max-w-2xl p-5">
        <form action={saveBranding} className="grid gap-5">
          <div className="grid gap-4 sm:grid-cols-2">
            <label className={label}>Cor principal
              <span className="mt-1.5 flex items-center gap-2">
                <input type="color" name="brand_color" defaultValue={brand} className="h-10 w-14 cursor-pointer rounded-md border border-line-strong bg-surface p-1" />
                <span className="text-[13px] font-normal text-muted">Botões, menu e gráfico principal</span>
              </span>
            </label>
            <label className={label}>Cor de destaque
              <span className="mt-1.5 flex items-center gap-2">
                <input type="color" name="accent_color" defaultValue={accent} className="h-10 w-14 cursor-pointer rounded-md border border-line-strong bg-surface p-1" />
                <span className="text-[13px] font-normal text-muted">Segunda cor dos gráficos</span>
              </span>
            </label>
          </div>

          <div className="grid gap-2">
            <span className={label}>Logo</span>
            {logo ? (
              <div className="flex flex-wrap items-center gap-4">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={logo} alt={`Logo de ${organization.name}`} className="h-16 w-auto max-w-[220px] rounded-md border border-line bg-surface object-contain p-1" />
                <label className="flex items-center gap-2 text-[13px] text-ink-soft"><input type="checkbox" name="remove_logo" value="1" /> Tirar o logo</label>
              </div>
            ) : <p className="text-[13px] text-muted">Sem logo: o menu mostra o nome da empresa.</p>}
            <input type="file" name="logo" accept="image/png,image/jpeg,image/webp" className="text-sm" />
            <p className="text-xs text-muted">PNG, JPG ou WebP, até 1 MB. Fica melhor com fundo transparente ou branco, no formato deitado.</p>
          </div>

          <div className="flex flex-wrap justify-end gap-2">
            <button name="reset" value="1" className="h-10 rounded-[10px] border border-line-strong bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-muted">Voltar às cores do Corban</button>
            <button className="h-10 rounded-[10px] bg-brand px-5 text-sm font-semibold text-white hover:bg-brand-strong">Salvar</button>
          </div>
        </form>
      </Card>
    </section>
  )
}
