import Link from 'next/link'
import { notFound } from 'next/navigation'
import { requireAppContext } from '@/lib/appContext'
import { atLeast } from '@/lib/rbac'
import { SubmitButton } from '@/components/SubmitButton'
import { SellerAccessScope } from '../SellerAccessScope'
import {
  addSellerBankAlias,
  addSubRule,
  saveSellerAddress,
  saveSellerCertification,
  saveSellerPaymentAccount,
  saveSellerProfile,
  setSellerActive,
  setSellerBankAliasActive,
  updateSeller,
} from '../actions'

const field='rounded-lg border border-slate-700 bg-slate-950 p-2 text-sm'
const card='rounded-2xl border border-slate-800 bg-slate-900 p-5'
const btn='rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-950'
const ghost='rounded-lg border border-slate-700 px-3 py-2 text-sm'
const CAT:Record<string,string>={pf:'PF',pj:'PJ',sub:'SUB'}
const ACCOUNT:Record<string,string>={checking:'Conta corrente',savings:'Poupança',payment:'Conta de pagamento',other:'Outra'}
const CERT_STATUS:Record<string,string>={active:'Ativa',expired:'Vencida',revoked:'Revogada',pending:'Pendente'}

export default async function SellerDetailPage({params}:{params:Promise<{id:string}>}){
  const {id}=await params
  const {supabase,membership}=await requireAppContext()
  if(!atLeast(membership.role,'supervisor'))return <section><p>Sem permissão.</p></section>
  const canEdit=atLeast(membership.role,'manager')

  const {data:seller}=await supabase.from('commercial_sellers')
    .select('id,name,seller_category,tax_id,seller_group_id,commission_group_id,branch_id,commission_payment_frequency,user_id,is_active')
    .eq('id',id).maybeSingle()
  if(!seller)notFound()

  const [profile,address,payments,certifications,sellerGroups,commissionGroups,banks,subRules,branches,aliases,providers]=await Promise.all([
    supabase.from('seller_profiles').select('*').eq('seller_id',id).maybeSingle(),
    supabase.from('seller_addresses').select('*').eq('seller_id',id).eq('is_current',true).maybeSingle(),
    supabase.from('seller_payment_accounts').select('*').eq('seller_id',id).order('valid_from',{ascending:false}).limit(20),
    supabase.from('seller_certifications').select('*').eq('seller_id',id).order('created_at',{ascending:false}),
    supabase.from('seller_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('commission_groups').select('id,name,is_active').order('sort_order').order('name'),
    supabase.from('banks').select('id,code,name,is_active').eq('is_active',true).order('name'),
    supabase.from('seller_sub_rule_versions').select('id,sub_share_pct,company_share_pct,effective_from,status').eq('seller_id',id).eq('status','published').order('effective_from',{ascending:false}),
    supabase.from('organization_branches').select('id,code,name,branch_type,is_active').order('branch_type').order('name'),
    supabase.from('seller_bank_aliases').select('id,source_key,external_user,bank_id,provider_id,is_active,created_at').eq('seller_id',id).order('created_at',{ascending:false}),
    supabase.from('providers').select('id,name,is_active').eq('is_active',true).order('name'),
  ])

  const currentPayment=(payments.data??[]).find(p=>p.is_current)??null
  const historicalPayments=(payments.data??[]).filter(p=>!p.is_current)
  const latestSub=(subRules.data??[])[0]

  return <section className="space-y-5">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <Link href="/app/cadastros/vendedores/consulta" className="text-sm text-slate-400 underline">← Consultar vendedores</Link>
        <h1 className="mt-3 text-3xl font-semibold">{seller.name}</h1>
        <p className="mt-1 text-sm text-slate-400">{(CAT[seller.seller_category]??seller.seller_category)+' · '+(seller.is_active?'Ativo':'Inativo')}</p>
      </div>
      {canEdit&&<form action={setSellerActive}>
        <input type="hidden" name="id" value={seller.id}/>
        <input type="hidden" name="active" value={seller.is_active?'false':'true'}/>
        <SubmitButton className={ghost}>{seller.is_active?'Inativar vendedor':'Reativar vendedor'}</SubmitButton>
      </form>}
    </div>

    <div className={card}>
      <h2 className="text-lg font-semibold">1. Identificação comercial</h2>
      <p className="mt-1 text-xs text-slate-500">Categoria, grupos e regras que determinam produção e comissão.</p>
      <form action={updateSeller} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="id" value={seller.id}/>
        <label className="text-xs text-slate-400">Nome / razão social<input required name="name" defaultValue={seller.name} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">CPF/CNPJ<input name="tax_id" defaultValue={seller.tax_id??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Categoria<select name="seller_category" defaultValue={seller.seller_category} className={field+' mt-1 block w-full'}><option value="pf">PF</option><option value="pj">PJ</option><option value="sub">SUB</option></select></label>
        <label className="text-xs text-slate-400">Grupo de Vendedor<select name="seller_group_id" defaultValue={seller.seller_group_id} className={field+' mt-1 block w-full'}>{(sellerGroups.data??[]).filter(x=>x.is_active||x.id===seller.seller_group_id).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        <label className="text-xs text-slate-400">Grupo de Comissão<select name="commission_group_id" defaultValue={seller.commission_group_id} className={field+' mt-1 block w-full'}>{(commissionGroups.data??[]).filter(x=>x.is_active||x.id===seller.commission_group_id).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        <label className="text-xs text-slate-400">Matriz / Filial<select name="branch_id" defaultValue={seller.branch_id} className={field+' mt-1 block w-full'}>{(branches.data??[]).filter(x=>x.is_active||x.id===seller.branch_id).map(x=><option key={x.id} value={x.id}>{x.branch_type==='matrix'?'Matriz · ':'Filial · '}{x.name}</option>)}</select></label>
        <label className="text-xs text-slate-400 md:col-span-2">Periodicidade de pagamento<select name="commission_payment_frequency" defaultValue={seller.commission_payment_frequency} className={field+' mt-1 block w-full'}><option value="daily">Diário</option><option value="weekly">Semanal</option><option value="monthly">Mensal</option></select></label>
        {canEdit&&<SubmitButton className={btn}>Salvar identificação comercial</SubmitButton>}
      </form>
      {seller.seller_category==='sub'&&<div className="mt-4 rounded-xl border border-amber-500/20 bg-amber-500/5 p-4">
        <div className="text-sm font-medium">Regra SUB</div>
        <p className="mt-1 text-xs text-slate-400">{latestSub?(String(latestSub.sub_share_pct)+'% para SUB / '+String(latestSub.company_share_pct)+'% para empresa · desde '+String(latestSub.effective_from).slice(0,10)):'Ainda sem regra SUB publicada.'}</p>
        {canEdit&&<form action={addSubRule} className="mt-3 flex flex-wrap gap-2">
          <input type="hidden" name="seller_id" value={seller.id}/><input type="hidden" name="component_key" value="all"/>
          <input required name="sub_share_pct" inputMode="decimal" placeholder="% do SUB" className={field}/>
          <input required name="effective_from" type="date" className={field}/>
          <SubmitButton className={ghost}>Publicar nova regra</SubmitButton>
        </form>}
      </div>}
    </div>

    <div className={card}>
      <h2 className="text-lg font-semibold">2. Dados cadastrais e contato</h2>
      <form action={saveSellerProfile} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="seller_id" value={seller.id}/>
        <label className="text-xs text-slate-400">Nome legal<input name="legal_name" defaultValue={profile.data?.legal_name??seller.name} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Nome fantasia<input name="trade_name" defaultValue={profile.data?.trade_name??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">E-mail<input type="email" name="profile_email" defaultValue={profile.data?.email??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Telefone<input name="phone" defaultValue={profile.data?.phone??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">WhatsApp<input name="whatsapp" defaultValue={profile.data?.whatsapp??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Nascimento / abertura<input type="date" name="birth_or_opening_date" defaultValue={profile.data?.birth_or_opening_date??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">RG / inscrição<input name="identity_or_registration_number" defaultValue={profile.data?.identity_or_registration_number??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Órgão emissor<input name="identity_issuer" defaultValue={profile.data?.identity_issuer??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Profissão / ocupação<input name="occupation" defaultValue={profile.data?.occupation??''} className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400 md:col-span-2">Observações<textarea name="notes" defaultValue={profile.data?.notes??''} className={field+' mt-1 min-h-24 w-full'}/></label>
        {canEdit&&<SubmitButton className={btn}>Salvar dados cadastrais</SubmitButton>}
      </form>
    </div>

    <div className={card}>
      <h2 className="text-lg font-semibold">3. Endereço</h2>
      <p className="mt-1 text-xs text-slate-500">Alterações preservam a versão anterior.</p>
      <form action={saveSellerAddress} className="mt-4 grid gap-3 md:grid-cols-3">
        <input type="hidden" name="seller_id" value={seller.id}/>
        <input name="postal_code" defaultValue={address.data?.postal_code??''} placeholder="CEP" className={field}/>
        <input name="street" defaultValue={address.data?.street??''} placeholder="Logradouro" className={field+' md:col-span-2'}/>
        <input name="number" defaultValue={address.data?.number??''} placeholder="Número" className={field}/>
        <input name="complement" defaultValue={address.data?.complement??''} placeholder="Complemento" className={field}/>
        <input name="neighborhood" defaultValue={address.data?.neighborhood??''} placeholder="Bairro" className={field}/>
        <input name="city" defaultValue={address.data?.city??''} placeholder="Cidade" className={field}/>
        <input name="state" maxLength={2} defaultValue={address.data?.state??''} placeholder="UF" className={field}/>
        {canEdit&&<SubmitButton className={btn}>Salvar endereço</SubmitButton>}
      </form>
    </div>

    <div className={card}>
      <h2 className="text-lg font-semibold">4. Acesso ao sistema e supervisão</h2>
      <SellerAccessScope sellerId={seller.id} userId={seller.user_id??null}/>
    </div>

    <div className={card}>
      <h2 className="text-lg font-semibold">5. Usuários de banco / aliases de produção</h2>
      <p className="mt-1 text-xs text-slate-500">Quando uma planilha trouxer um destes usuários, o importador poderá reconhecer automaticamente este vendedor.</p>
      <div className="mt-3 space-y-2">
        {!(aliases.data??[]).length
          ? <p className="text-sm text-slate-500">Nenhum usuário externo cadastrado.</p>
          : (aliases.data??[]).map(a=><div key={a.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-slate-800 p-3 text-sm">
              <div><div className="font-medium">{a.source_key+' · '+a.external_user}</div><div className="mt-1 text-xs text-slate-500">{a.is_active?'Ativo':'Inativo'}</div></div>
              {canEdit&&<form action={setSellerBankAliasActive}>
                <input type="hidden" name="seller_id" value={seller.id}/>
                <input type="hidden" name="alias_id" value={a.id}/>
                <input type="hidden" name="active" value={a.is_active?'false':'true'}/>
                <SubmitButton className={ghost}>{a.is_active?'Inativar':'Reativar'}</SubmitButton>
              </form>}
            </div>)}
      </div>
      {canEdit&&<form action={addSellerBankAlias} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="seller_id" value={seller.id}/>
        <label className="text-xs text-slate-400">Banco<select name="bank_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Não informar</option>{(banks.data??[]).map(b=><option key={b.id} value={b.id}>{(b.code?String(b.code)+' · ':'')+b.name}</option>)}</select></label>
        <label className="text-xs text-slate-400">Provedor / origem<select name="provider_id" defaultValue="" className={field+' mt-1 block w-full'}><option value="">Não informar</option>{(providers.data??[]).map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
        <label className="text-xs text-slate-400">Chave da origem no arquivo<input required name="source_key" placeholder="Ex.: pan, daycoval" className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Usuário/login no banco<input required name="external_user" placeholder="Ex.: cleuton.smart" className={field+' mt-1 block w-full'}/></label>
        <SubmitButton className={btn}>Adicionar usuário de banco</SubmitButton>
      </form>}
    </div>

    {atLeast(membership.role,'manager')&&<div className={card}>
      <h2 className="text-lg font-semibold">6. Dados para pagamento de comissão</h2>
      <p className="mt-1 text-xs text-slate-500">Conta/Pix é versionado para preservar o histórico usado em fechamento e auditoria.</p>
      <form action={saveSellerPaymentAccount} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="seller_id" value={seller.id}/>
        <label className="text-xs text-slate-400">Banco<select name="bank_id" defaultValue={currentPayment?.bank_id??''} className={field+' mt-1 block w-full'}><option value="">Somente PIX / sem banco</option>{(banks.data??[]).map(b=><option key={b.id} value={b.id}>{(b.code?String(b.code)+' · ':'')+b.name}</option>)}</select></label>
        <label className="text-xs text-slate-400">Tipo de conta<select name="account_type" defaultValue={currentPayment?.account_type??''} className={field+' mt-1 block w-full'}><option value="">Selecione</option>{Object.entries(ACCOUNT).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></label>
        <input name="branch" defaultValue={currentPayment?.branch??''} placeholder="Agência" className={field}/>
        <div className="grid grid-cols-[1fr_100px] gap-2"><input name="account_number" defaultValue={currentPayment?.account_number??''} placeholder="Conta" className={field}/><input name="account_digit" defaultValue={currentPayment?.account_digit??''} placeholder="Dígito" className={field}/></div>
        <input required name="holder_name" defaultValue={currentPayment?.holder_name??profile.data?.legal_name??seller.name} placeholder="Titular" className={field}/>
        <input required name="holder_document" defaultValue={currentPayment?.holder_document??seller.tax_id??''} placeholder="CPF/CNPJ do titular" className={field}/>
        <label className="text-xs text-slate-400">Tipo de chave PIX<select name="pix_key_type" defaultValue={currentPayment?.pix_key_type??''} className={field+' mt-1 block w-full'}><option value="">Sem PIX</option><option value="cpf">CPF</option><option value="cnpj">CNPJ</option><option value="email">E-mail</option><option value="phone">Telefone</option><option value="random">Aleatória</option></select></label>
        <input name="pix_key" defaultValue={currentPayment?.pix_key??''} placeholder="Chave PIX" className={field}/>
        <SubmitButton className={btn}>Salvar nova versão de pagamento</SubmitButton>
      </form>
      {historicalPayments.length>0&&<details className="mt-4">
        <summary className="cursor-pointer text-xs underline">Ver histórico de contas ({historicalPayments.length})</summary>
        <div className="mt-3 space-y-2">{historicalPayments.map(p=><div key={p.id} className="rounded-lg border border-slate-800 p-3 text-xs text-slate-400">
          {p.bank_name_snapshot+' · '+(p.branch||'—')+' · '+(p.account_number||'sem conta')+' · PIX '+(p.pix_key||'—')+' · válida de '+new Date(p.valid_from).toLocaleDateString('pt-BR')+' até '+(p.valid_until?new Date(p.valid_until).toLocaleDateString('pt-BR'):'—')}
        </div>)}</div>
      </details>}
    </div>}

    <div className={card}>
      <h2 className="text-lg font-semibold">7. Certificações</h2>
      <div className="mt-3 space-y-2">{!(certifications.data??[]).length?<p className="text-sm text-slate-500">Nenhuma certificação cadastrada.</p>:(certifications.data??[]).map(c=><div key={c.id} className="rounded-lg border border-slate-800 p-3 text-sm">
        <div className="font-medium">{c.name}</div>
        <div className="mt-1 text-xs text-slate-400">{(c.issuer||'Emissor não informado')+' · '+(c.certificate_number||'sem número')+' · '+(CERT_STATUS[c.status]??c.status)+(c.expires_at?' · validade '+String(c.expires_at):'')}</div>
      </div>)}</div>
      {canEdit&&<form action={saveSellerCertification} className="mt-4 grid gap-3 md:grid-cols-2">
        <input type="hidden" name="seller_id" value={seller.id}/>
        <input required name="certification_name" placeholder="Certificação" className={field}/>
        <input name="issuer" placeholder="Emissor" className={field}/>
        <input name="certificate_number" placeholder="Número do certificado" className={field}/>
        <select name="status" defaultValue="active" className={field}><option value="active">Ativa</option><option value="pending">Pendente</option><option value="expired">Vencida</option><option value="revoked">Revogada</option></select>
        <label className="text-xs text-slate-400">Emissão<input type="date" name="issued_at" className={field+' mt-1 block w-full'}/></label>
        <label className="text-xs text-slate-400">Validade<input type="date" name="expires_at" className={field+' mt-1 block w-full'}/></label>
        <textarea name="certification_notes" placeholder="Observações" className={field+' md:col-span-2 min-h-20'}/>
        <SubmitButton className={btn}>Adicionar certificação</SubmitButton>
      </form>}
    </div>
  </section>
}
