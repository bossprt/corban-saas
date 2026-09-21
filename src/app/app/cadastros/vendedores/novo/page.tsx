import Link from 'next/link'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { createSeller } from '../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-5 py-3 text-sm font-semibold text-slate-950'
const ACCOUNT:Record<string,string>={checking:'Conta corrente',savings:'Poupança',payment:'Conta de pagamento',other:'Outra'}

export default async function NewSellerPage(){
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'manager'))return <section><p>Sem permissão.</p></section>

  const [sellerGroups,commissionGroups,branches,banks,providers]=await Promise.all([
    supabase.from('seller_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('commission_groups').select('id,name,is_active').eq('is_active',true).order('sort_order').order('name'),
    supabase.from('organization_branches').select('id,code,name,branch_type,is_active').eq('is_active',true).order('branch_type').order('name'),
    supabase.from('banks').select('id,code,name,is_active').eq('is_active',true).order('name'),
    supabase.from('providers').select('id,name,is_active').eq('is_active',true).order('name'),
  ])

  const matrix=(branches.data??[]).find(b=>b.branch_type==='matrix')

  return <section className="space-y-5">
    <div>
      <Link href="/app/cadastros/vendedores/consulta" className="text-sm text-slate-400 underline">← Consultar vendedores</Link>
      <h1 className="mt-3 text-3xl font-semibold">Cadastrar vendedor</h1>
      <p className="mt-2 max-w-3xl text-sm text-slate-400">Cadastre o vendedor completo. Depois de salvar, a ficha individual continuará disponível para alterações e histórico.</p>
    </div>

    <form action={createSeller} className="space-y-5">
      <div className={card}>
        <h2 className="text-lg font-semibold">1. Identificação e classificação</h2>
        <p className="mt-1 text-xs text-slate-500">A classificação do vendedor é interna (ex.: Bronze, Ouro, Elite) e não altera comissão automaticamente.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="text-xs text-slate-400">Nome / razão social<input required name="name" maxLength={160} className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">CPF/CNPJ<input name="tax_id" inputMode="numeric" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Categoria<select required name="seller_category" defaultValue="pf" className={field+' mt-1 block w-full'}><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select></label>
          <label className="text-xs text-slate-400">Classificação do vendedor <span className="text-slate-500">(Grupo de Vendedores)</span><select required name="seller_group_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="" disabled>Selecione</option>{(sellerGroups.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
          <label className="text-xs text-slate-400">Grupo de Comissão<select required name="commission_group_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="" disabled>Selecione</option>{(commissionGroups.data??[]).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
          <label className="text-xs text-slate-400">Matriz / Filial<select required name="branch_id" defaultValue={matrix?.id??''} className={field+' mt-1 block w-full'}>{(branches.data??[]).map(x=><option key={x.id} value={x.id}>{x.branch_type==='matrix'?'Matriz · ':'Filial · '}{x.name}</option>)}</select></label>
          <label className="text-xs text-slate-400 md:col-span-2">Periodicidade de pagamento da comissão<select required name="commission_payment_frequency" defaultValue="monthly" className={field+' mt-1 block w-full'}><option value="daily">Diário</option><option value="weekly">Semanal</option><option value="monthly">Mensal</option></select></label>
        </div>
      </div>

      <div className={card}>
        <h2 className="text-lg font-semibold">2. Dados cadastrais e contato</h2>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="text-xs text-slate-400">Nome legal<input name="legal_name" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Nome fantasia<input name="trade_name" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">E-mail de contato<input type="email" name="profile_email" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Telefone<input name="phone" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">WhatsApp<input name="whatsapp" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Nascimento / abertura<input type="date" name="birth_or_opening_date" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">RG / inscrição<input name="identity_or_registration_number" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Órgão emissor<input name="identity_issuer" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Profissão / ocupação<input name="occupation" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400 md:col-span-2">Observações<textarea name="notes" className={field+' mt-1 min-h-24 w-full'}/></label>
        </div>
      </div>

      <div className={card}>
        <h2 className="text-lg font-semibold">3. Endereço</h2>
        <div className="mt-4 grid gap-3 md:grid-cols-3">
          <input name="postal_code" placeholder="CEP" className={field}/>
          <input name="street" placeholder="Logradouro" className={field+' md:col-span-2'}/>
          <input name="number" placeholder="Número" className={field}/>
          <input name="complement" placeholder="Complemento" className={field}/>
          <input name="neighborhood" placeholder="Bairro" className={field}/>
          <input name="city" placeholder="Cidade" className={field}/>
          <input name="state" maxLength={2} placeholder="UF" className={field}/>
        </div>
      </div>

      <div className={card}>
        <h2 className="text-lg font-semibold">4. Acesso externo ao sistema</h2>
        <p className="mt-1 text-xs text-slate-500">O vendedor nasce como Operador e vê somente a própria comissão. A senha vai direto para o Supabase Auth e não é salva no cadastro.</p>
        <label className="mt-4 flex items-start gap-2 rounded-lg border border-slate-800 bg-slate-950/60 p-3 text-sm">
          <input type="checkbox" name="create_access" defaultChecked className="mt-1"/>
          <span><strong>Criar acesso agora</strong><span className="mt-1 block text-xs text-slate-400">Desmarque apenas para parceiro externo que não utilizará o Corban OS.</span></span>
        </label>
        <div className="mt-3 grid gap-3 md:grid-cols-2">
          <label className="text-xs text-slate-400">Login (e-mail)<input type="email" name="email" autoComplete="off" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Senha inicial<input type="password" name="password" autoComplete="new-password" className={field+' mt-1 block w-full'}/><span className="mt-1 block text-[11px] text-slate-500">Mínimo 12 caracteres, com maiúscula, minúscula, número e símbolo.</span></label>
        </div>
      </div>

      <div className={card}>
        <h2 className="text-lg font-semibold">5. Dados para pagamento de comissão</h2>
        <p className="mt-1 text-xs text-slate-500">Opcional no primeiro cadastro. Se preenchido, já nasce como versão vigente da conta de pagamento.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="text-xs text-slate-400">Banco<select name="payment_bank_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Somente PIX / não informar agora</option>{(banks.data??[]).map(b=><option key={b.id} value={b.id}>{(b.code?String(b.code)+' · ':'')+b.name}</option>)}</select></label>
          <label className="text-xs text-slate-400">Tipo de conta<select name="account_type" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Selecione</option>{Object.entries(ACCOUNT).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></label>
          <input name="branch" placeholder="Agência" className={field}/>
          <div className="grid grid-cols-[1fr_100px] gap-2"><input name="account_number" placeholder="Conta" className={field}/><input name="account_digit" placeholder="Dígito" className={field}/></div>
          <input name="holder_name" placeholder="Titular" className={field}/>
          <input name="holder_document" placeholder="CPF/CNPJ do titular" className={field}/>
          <label className="text-xs text-slate-400">Tipo de chave PIX<select name="pix_key_type" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Sem PIX</option><option value="cpf">CPF</option><option value="cnpj">CNPJ</option><option value="email">E-mail</option><option value="phone">Telefone</option><option value="random">Aleatória</option></select></label>
          <input name="pix_key" placeholder="Chave PIX" className={field}/>
        </div>
      </div>

      <div className={card}>
        <h2 className="text-lg font-semibold">6. Usuário do banco para reconhecimento automático</h2>
        <p className="mt-1 text-xs text-slate-500">Opcional. Use quando relatórios/planilhas identificam o produtor por login/usuário em vez de CPF/CNPJ.</p>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <label className="text-xs text-slate-400">Banco<select name="bank_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Não informar</option>{(banks.data??[]).map(b=><option key={b.id} value={b.id}>{(b.code?String(b.code)+' · ':'')+b.name}</option>)}</select></label>
          <label className="text-xs text-slate-400">Provedor / origem<select name="provider_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Não informar</option>{(providers.data??[]).map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <label className="text-xs text-slate-400">Chave da origem no arquivo<input name="bank_source_key" placeholder="Ex.: pan, daycoval" className={field+' mt-1 block w-full'}/></label>
          <label className="text-xs text-slate-400">Usuário/login no banco<input name="bank_external_user" placeholder="Ex.: cleuton.smart" className={field+' mt-1 block w-full'}/></label>
        </div>
      </div>

      <div className="flex justify-end">
        <SubmitButton className={btn}>Cadastrar vendedor</SubmitButton>
      </div>
    </form>
  </section>
}
