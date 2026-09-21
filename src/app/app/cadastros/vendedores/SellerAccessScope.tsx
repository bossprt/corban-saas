import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { ROLE_LABEL } from '@/lib/team'
import { memberEmails } from '@/lib/team.server'
import { bindSellerUser, setSellerSupervision } from './actions'
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

  const [{ data: members }, { data: supervisions }] = await Promise.all([
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
  ])

  const ids = (members ?? []).map(m => m.user_id)
  const emails = await memberEmails(ids)
  const supervisors = (members ?? []).filter(m => m.role === 'supervisor')
  const activeSupervisorIds = new Set((supervisions ?? []).map(s => s.supervisor_user_id))

  return <div className="mt-3 rounded-xl border border-slate-800 bg-slate-950/50 p-4">
    <h3 className="text-sm font-semibold">Acesso à comissão</h3>
    <p className="mt-1 text-xs text-slate-500">Vincule o vendedor ao login que verá a própria comissão e defina quais supervisores podem acompanhar este vendedor.</p>

    <form action={bindSellerUser} className="mt-3 flex flex-wrap items-end gap-2">
      <input type="hidden" name="seller_id" value={sellerId}/>
      <label className="text-xs text-slate-400">
        Login do vendedor
        <select name="user_id" defaultValue={userId ?? ''} className={field + ' mt-1 block min-w-72'}>
          <option value="">Sem login vinculado</option>
          {(members ?? []).map(m => <option key={m.user_id} value={m.user_id}>
            {emails.get(m.user_id) ?? m.user_id.slice(0,8)} · {ROLE_LABEL[m.role] ?? m.role}
          </option>)}
        </select>
      </label>
      <SubmitButton className={ghost}>Salvar vínculo</SubmitButton>
    </form>

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
