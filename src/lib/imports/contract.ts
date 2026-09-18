export type ImportRecordKind='table_offer'|'proposal'|'commission'|'payment'|'status'|'network_production'|'other'
export type ImportSourceKey='daycoval'|'efetiva_mais'|'bevicred'|string

export type NormalizedImportRow={
 recordKind:ImportRecordKind
 bankKey:string|null
 externalProposalNumber:string|null
 producerTaxId:string|null
 externalTableCode:string|null
 externalTableName:string|null
 operationType:string|null
 term:number|null
 rate:string|null
 commissionUpfront:string|null
 commissionDeferred:string|null
 amount:string|null
 normalizedPayload:Record<string,unknown>
}

export type ParsedImportRow={
 rowNumber:number
 rawPayload:Record<string,unknown>
 normalized:NormalizedImportRow
}

export interface ImportAdapter{
 readonly key:string
 readonly version:string
 canParse(input:{filename:string;mimeType?:string|null;headers?:string[]}):boolean
 parse(input:{filename:string;rows:Record<string,unknown>[]}):ParsedImportRow[]
}

export function normalizeExternalProposalNumber(value:unknown):string|null{
 if(value===null||value===undefined)return null
 const normalized=String(value).trim()
 return normalized||null
}

export function normalizeTaxId(value:unknown):string|null{
 if(value===null||value===undefined)return null
 const digits=String(value).replace(/\D/g,'')
 return digits||null
}

export function decimalString(value:unknown):string|null{
 if(value===null||value===undefined||value==='')return null
 if(typeof value==='number'&&Number.isFinite(value))return String(value)
 const raw=String(value).trim().replace(/\s/g,'')
 if(!raw)return null
 const normalized=raw.includes(',')?raw.replace(/\./g,'').replace(',','.'):raw
 return /^-?\d+(\.\d+)?$/.test(normalized)?normalized:null
}
