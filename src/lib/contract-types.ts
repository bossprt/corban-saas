export type ContractTypeSetting = {
  contract_type_id:string
  is_enabled:boolean
  use_in_pipeline:boolean
  use_in_commission:boolean
}

export type ContractTypeRow = {
  id:string
  name:string
  tech_key:string
  is_active:boolean
  organization_id?:string|null
}

export function effectiveContractTypes(
  types: readonly ContractTypeRow[],
  settings: readonly ContractTypeSetting[],
  use: 'general'|'pipeline'|'commission'='general',
) {
  const byId=new Map(settings.map(s=>[s.contract_type_id,s]))
  return types.filter(t=>{
    if(!t.is_active)return false
    const s=byId.get(t.id)
    if(s?.is_enabled===false)return false
    if(use==='pipeline'&&s?.use_in_pipeline===false)return false
    if(use==='commission'&&s?.use_in_commission===false)return false
    return true
  })
}
