import { createHash } from 'crypto'
import { importAdapters,bevicredAdapter,daycovalAdapter,efetivaMaisAdapter,commissionStatementAdapter,paymentStatementAdapter,networkPaymentStatementAdapter } from './adapters'
import type { ImportAdapter,ParsedImportRow } from './contract'

export function sha256(content:Buffer|string){return createHash('sha256').update(content).digest('hex')}

export function selectImportAdapter(input:{filename:string;mimeType?:string|null;headers?:string[];sourceKey?:string}):ImportAdapter|null{
 if(input.sourceKey==='daycoval')return daycovalAdapter
 if(input.sourceKey==='efetiva_mais')return efetivaMaisAdapter
 if(input.sourceKey==='bevicred')return bevicredAdapter
 if(input.sourceKey==='commission_statement')return commissionStatementAdapter
 if(input.sourceKey==='payment_statement')return paymentStatementAdapter
 if(input.sourceKey==='network_payment_statement')return networkPaymentStatementAdapter
 const matches=importAdapters.filter(a=>a.canParse(input))
 return matches.length===1?matches[0]:null
}

export function validateParsedRows(rows:ParsedImportRow[]){
 const seen=new Set<number>()
 for(const row of rows){
  if(!Number.isInteger(row.rowNumber)||row.rowNumber<1)throw new Error('invalid_row_number')
  if(seen.has(row.rowNumber))throw new Error('duplicate_row_number')
  seen.add(row.rowNumber)
  if(!row.rawPayload||typeof row.rawPayload!=='object')throw new Error('invalid_raw_payload')
  if(!row.normalized.recordKind)throw new Error('missing_record_kind')
 }
 return rows
}

export function proposalIdentityKey(bankKey:string|null,externalProposalNumber:string|null){
 if(!externalProposalNumber)return null
 return `${bankKey??'unknown'}::${externalProposalNumber.trim()}`
}


export function financialEventTypeForAdapter(adapter:ImportAdapter):'commission_reported'|'payment_received'|'downstream_paid'|null{
 if(adapter.financialSemantic==='commission_statement')return 'commission_reported'
 if(adapter.financialSemantic==='payment_statement')return 'payment_received'
 if(adapter.financialSemantic==='network_payment_statement')return 'downstream_paid'
 return null
}

export function assertFinancialPublicationAllowed(adapter:ImportAdapter){
 const eventType=financialEventTypeForAdapter(adapter)
 if(!eventType)throw new Error('source_does_not_prove_financial_fact')
 return eventType
}
