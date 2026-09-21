import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { memberEmails } from '@/lib/team.server'
import { setSellerSupervision } from './actions'
import { SubmitButton } from '@/components/SubmitButton'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'

export async function SellerAccessScope({
  sellerId,
  userId,
}: {
  sellerId: string
  userId: string | null
}) {
  const { supabase, membership } = await requireAppContext()
  if (!atLeast(membership.role, 'manager')) return null

  const [{ data: members }, { data: supervisions }, { data: invitations }] = await Promise.all([
    supabase
      .from('organization_memberships')
      .select('user_id,role,status')
      .eq('status', 'active')
      .order('role'),
    supabase
      .from('seller_supervisions')
      .select('id,supervisor_user_id,is_active')
      .eq('seller_id', sellerId)
      .eq('is_active', true),
    supabase
      .from('organization_invitations')
      .select('id,email,status,expires_at')
      .eq('seller_id', sellerId)
      .order('created_at', { ascending: false })
      .limit(1),
  ])

  const ids = (members ?? []).map(m => m.user_id)
  const emails = await memberEmails(ids)
  const supervisors = (members ?? []).filter(m => m.role === 'supervisor')
  const activeSupervisorIds = new Set((supervisions ?? []).map(s => s.supervisor_user_id))
  const pending = (invitations ?? [])[0]

  return <div className="mt-3 rounded-xl border border-slate-800 bg-slate-950/50 p-4">
    <h3 className="text-sm font-semibold">Acesso e supervisão</h3>
    <div className="mt-2 text-xs">
      {userId
        ? <p className="text-emerald-300">Acesso ativo · {emails.get(userId) ?? userId.slice(0,8)} · Operador · vê somente a própria comissão.</p>
        : pending?.status==='pending'
          ? <p className="text-amber-200">Convite pendente · {pending.email} · o vínculo ao vendedor será automático quando o convite for aceito.</p>
          : <p className="text-slate-500">Sem acesso ao sistema. Este vendedor pode atuar como parceiro externo.</p>}
    </div>

    <div className="mt-4">
      <div className="text-xs font-medium text-slate-300">Supervisores deste vendedor</div>
      <div className="mt-2 flex flex-wrap gap-2">
        {(supervisions ?? []).map(s => <form key={s.id} action={setSellerSupervision} className="flex items-center gap-2 rounded-lg border border-slate-800 px-3 py-2 text-xs">
          <input type="hidden" name="seller_id" value={sellerId}/>
          <input type="hidden" name="supervisor_user_id" value={s.supervisor_user_id}/>
          <input type="hidden" name="active" value="false"/>
          <span>{emails.get(s.supervisor_user_id) ?? s.supervisor_user_id.slice(0,8)}</span>
          <SubmitButton className="text-red-200 underline">Remover</SubmitButton>
        </form>)}
        {!(supervisions ?? []).length && <span className="text-xs text-slate-500">Nenhum supervisor vinculado.</span>}
      </div>

      {supervisors.some(s => !activeSupervisorIds.has(s.user_id)) && <form action={setSellerSupervision} className="mt-3 flex flex-wrap items-end gap-2">
        <input type="hidden" name="seller_id" value={sellerId}/>
        <input type="hidden" name="active" value="true"/>
        <label className="text-xs text-slate-400">
          Adicionar supervisor
          <select required name="supervisor_user_id" defaultValue="" className={field + ' mt-1 block min-w-72'}>
            <option value="" disabled>Selecione</option>
            {supervisors.filter(s => !activeSupervisorIds.has(s.user_id)).map(s => <option key={s.user_id} value={s.user_id}>
              {emails.get(s.user_id) ?? s.user_id.slice(0,8)}
            </option>)}
          </select>
        </label>
        <SubmitButton className={ghost}>Adicionar</SubmitButton>
      </form>}
    </div>
  </div>
}
