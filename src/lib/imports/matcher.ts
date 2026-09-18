import type { NormalizedImportRow } from './contract'

export type ProposalIdentity={id:string;institutionKey:string;externalProposalNumber:string}
export type TableIdentity={id:string;channelId:string;externalCode:string}
export type MatchCandidate={
 proposalId:string|null
 productTableId:string|null
 channelId:string|null
 strength:'exact'|'strong'|'probable'|'ambiguous'|'none'
 basis:Record<string,unknown>
 status:'suggested'|'human_required'
}

export function matchNormalizedRow(row:NormalizedImportRow,input:{proposals:ProposalIdentity[];tables:TableIdentity[]}):MatchCandidate{
 if(row.externalProposalNumber){
  const number=row.externalProposalNumber.trim()
  const scoped=input.proposals.filter(p=>p.externalProposalNumber===number&&(!row.bankKey||p.institutionKey===row.bankKey))
  if(scoped.length===1)return{proposalId:scoped[0].id,productTableId:null,channelId:null,strength:'exact',basis:{externalProposalNumber:number,institutionKey:scoped[0].institutionKey},status:'suggested'}
  if(scoped.length>1)return{proposalId:null,productTableId:null,channelId:null,strength:'ambiguous',basis:{externalProposalNumber:number,candidates:scoped.length},status:'human_required'}
 }
 if(row.externalTableCode){
  const code=row.externalTableCode.trim()
  const tables=input.tables.filter(t=>t.externalCode===code)
  if(tables.length===1)return{proposalId:null,productTableId:tables[0].id,channelId:tables[0].channelId,strength:'strong',basis:{externalTableCode:code},status:'suggested'}
  if(tables.length>1)return{proposalId:null,productTableId:null,channelId:null,strength:'ambiguous',basis:{externalTableCode:code,candidates:tables.length},status:'human_required'}
 }
 return{proposalId:null,productTableId:null,channelId:null,strength:'none',basis:{reason:'no_deterministic_identity'},status:'human_required'}
}
