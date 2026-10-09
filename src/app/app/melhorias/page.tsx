import { Lightbulb } from 'lucide-react'
import { Badge, Card, CardHeader, PageHeader, type Tone } from '@/components/ui'
import { SubmitButton } from '@/components/SubmitButton'
import { requireAppContext } from '@/lib/appContext'
import { IMPROVEMENT_KIND, IMPROVEMENT_STATUS } from '@/lib/improvements'
import { atLeast } from '@/lib/rbac'
import { memberEmails } from '@/lib/team.server'
import { submitImprovement } from './actions'

const ERRORS: Record<string, string> = {
  tipo: 'Escolha o tipo.', titulo: 'O título precisa ter de 3 a 120 letras.', descricao: 'Descreva com pelo menos 10 letras (até 4.000).',
  limite: 'Limite de 20 solicitações por dia atingido. Tente amanhã.', envio: 'Não foi possível enviar agora. Tente de novo.',
}
const lbl = 'block text-[13px] font-medium text-ink-soft'
type Row = { id: string; protocol: string; kind: string; title: string; body: string; page_path: string | null; status: string; response: string | null; created_by: string; created_at: string }

// Melhorias (owner, 08/10/2026): any user suggests an improvement, reports an error or asks a question and gets a
// protocol; the platform answers whether it will be done. Each user sees their own; the company administrator, all.
export default async function ImprovementsPage({ searchParams }: { searchParams: Promise<{ de?: string; protocolo?: string; erro?: string }> }) {
  const { supabase, user, membership } = await requireAppContext()
  const sp = await searchParams
  const from = /^\/app[A-Za-z0-9/_-]{0,195}$/.test(sp.de ?? '') ? sp.de! : ''
  const { data } = await supabase.from('improvement_requests').select('id,protocol,kind,title,body,page_path,status,response,created_by,created_at')
    .order('created_at', { ascending: false }).limit(200)
  const rows = (data ?? []) as Row[]
  const admin = atLeast(membership.role, 'admin')
  const who = admin ? await memberEmails([...new Set(rows.map(r => r.created_by))]) : new Map<string, string>()
  const protocol = /^MEL-\d{4}-\d{4,}$/.test(sp.protocolo ?? '') ? sp.protocolo : null
  return (
    <section>
      <PageHeader title="Sugerir melhoria" description="Ajude a melhorar o Corban: sugira uma melhoria, avise de um erro ou tire uma dúvida. Cada pedido recebe um protocolo, e a resposta aparece aqui." />
      {protocol && <p role="status" className="mb-4 rounded-[10px] border border-[#86EFAC] bg-[#F0FDF4] px-4 py-3 text-sm text-[#166534]">Solicitação registrada. Protocolo <strong>{protocol}</strong>. Acompanhe a resposta abaixo.</p>}
      {sp.erro && ERRORS[sp.erro] && <p role="alert" className="mb-4 rounded-[10px] border border-[#FCD34D] bg-[#FFFBEB] px-4 py-3 text-sm text-[#92400E]">{ERRORS[sp.erro]}</p>}
      <Card className="mb-6 p-5">
        <form action={submitImprovement} className="grid gap-3">
          <input type="hidden" name="page" value={from} />
          <div className="grid gap-3 sm:grid-cols-[220px_1fr]">
            <label className={lbl}>Tipo<select name="kind" required defaultValue="improvement" className="field mt-1.5">{Object.entries(IMPROVEMENT_KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
            <label className={lbl}>Título<input name="title" required minLength={3} maxLength={120} placeholder="Ex.: Filtro por convênio em Contratos" className="field mt-1.5" /></label>
          </div>
          <label className={lbl}>Descrição<textarea name="body" required minLength={10} maxLength={4000} rows={5} placeholder="O que você precisa, onde e por quê. Se for um erro: o que fez e o que apareceu." className="field mt-1.5" /></label>
          <p className="text-xs text-muted">{from ? `Tela de origem: ${from}. ` : ''}Não coloque CPF, senhas nem dados de clientes.</p>
          <div><SubmitButton className="inline-flex h-10 items-center gap-1.5 rounded-[10px] bg-brand px-4 text-sm font-semibold text-white hover:bg-brand-strong" pendingText="Enviando..."><Lightbulb size={16} aria-hidden />Enviar solicitação</SubmitButton></div>
        </form>
      </Card>
      <Card>
        <CardHeader title={<span className="flex items-center gap-2">{admin ? 'Solicitações da empresa' : 'Minhas solicitações'} <Badge tone="neutral">{rows.length}</Badge></span>} />
        <ul className="grid gap-2 p-5 pt-3">
          {rows.map(r => {
            const [st, tone] = IMPROVEMENT_STATUS[r.status] ?? [r.status, 'neutral' as Tone]
            return (
              <li key={r.id} className="rounded-[12px] border border-line px-4 py-3">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <span className="font-mono text-xs text-muted">{r.protocol}</span>
                  <span className="font-medium text-ink">{r.title}</span>
                  <Badge tone="neutral">{IMPROVEMENT_KIND[r.kind] ?? r.kind}</Badge>
                  <Badge tone={tone}>{st}</Badge>
                  <span className="ml-auto text-xs text-muted">{new Date(r.created_at).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })}{admin ? ` · ${r.created_by === user.id ? 'você' : (who.get(r.created_by) ?? 'usuário')}` : ''}</span>
                </div>
                <p className="mt-1 whitespace-pre-wrap text-sm text-ink-soft">{r.body}</p>
                {r.response && <p className="mt-2 rounded-[10px] bg-surface-muted px-3 py-2 text-sm text-ink"><span className="font-medium">Resposta:</span> {r.response}</p>}
              </li>
            )
          })}
          {!rows.length && <li className="text-sm text-muted">Nenhuma solicitação ainda.</li>}
        </ul>
      </Card>
    </section>
  )
}
