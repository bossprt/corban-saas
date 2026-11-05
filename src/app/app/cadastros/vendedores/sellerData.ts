// The seller form read into the shape save_seller takes. Shared by the seller file and the public registration link
// (05/11/2026), which posts the same field names without the administrator's ones.
const text=(f:FormData,k:string)=>String(f.get(k)??'').trim()

// The rows of a repeated block, read in order: every row posts the same names.
function rows(f:FormData,names:string[]):Record<string,string>[]{
  const cols=names.map(n=>f.getAll(n).map(v=>String(v).trim()))
  const n=Math.max(0,...cols.map(c=>c.length))
  return Array.from({length:n},(_,i)=>Object.fromEntries(names.map((k,j)=>[k,cols[j][i]??''])))
}

export function sellerData(f:FormData):Record<string,unknown>{
  const mobile=text(f,'mobile')
  const profile:Record<string,string>={
    trade_name:text(f,'trade_name'),birth_date:text(f,'birth_date'),rg:text(f,'rg'),rg_issuer:text(f,'rg_issuer'),rg_issued_on:text(f,'rg_issued_on'),
    mother_name:text(f,'mother_name'),father_name:text(f,'father_name'),mobile,
    whatsapp:f.get('whatsapp_same')==='on'?mobile:text(f,'whatsapp'),other_phones:text(f,'other_phones'),email:text(f,'email'),
  }
  for(const p of ['','business_'])for(const k of ['zip','street','number','complement','district','city','state'])profile[`${p}${k}`]=text(f,`${p}${k}`)

  const data:Record<string,unknown>={
    name:text(f,'name'),tax_id:text(f,'tax_id'),category:text(f,'seller_category'),group_id:text(f,'commission_group_id'),
    branch_id:text(f,'branch_id'),profile,internal:f.get('internal')==='on',
    // Part C3: how often the seller is paid and whether they receive the deferred.
    payment_frequency:text(f,'payment_frequency')||'daily',receives_deferred:f.get('receives_deferred')==='on',
    contacts:rows(f,['contact_name','contact_cpf','contact_role','contact_mobile','contact_email'])
      .filter(c=>Object.values(c).some(Boolean))
      .map(c=>({name:c.contact_name,cpf:c.contact_cpf,role:c.contact_role,mobile:c.contact_mobile,email:c.contact_email})),
  }
  // Bank accounts travel only when the form carried them (who cannot see bank data never overwrites it).
  if(f.get('accounts_included')==='1'){
    const primary=Number(text(f,'primary_account')||'0')
    const accountRows=rows(f,['account_id','remove_account','has_payee','transfer_method','pix_key_type','pix_key','account_type','bank_code','bank_name','branch','account_number','account_digit','holder_name','holder_document','account_note'])
    data.accounts=accountRows.map((a,i)=>({a,i})).filter(({a})=>a.account_id||a.pix_key||a.bank_code||a.account_number||a.branch).map(({a,i})=>{
      const payee=a.has_payee==='1'
      return {
        id:a.account_id||null,remove:a.remove_account==='1',primary:i===primary,transfer_method:a.transfer_method,
        pix_key_type:a.pix_key_type,pix_key:a.pix_key,account_type:a.account_type,bank_code:a.bank_code,bank_name:a.bank_name,branch:a.branch,
        account_number:a.account_number,account_digit:a.account_digit,
        holder_name:payee?a.holder_name:'',holder_document:payee?a.holder_document:'',note:a.account_note,
      }
    })
  }
  return data
}
