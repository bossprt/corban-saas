import { createHash } from 'crypto'
import { decimalString,ImportAdapter,NormalizedImportRow,ParsedImportRow } from './contract'

// Adapter `2tech/busca_contrato_file` (contract 1.0.0). Provider = 2Tech; the financial institution
// is a separate dimension and is only read from an explicit column, never defaulted from the provider.
// Field semantics mirror the live `integration_field_mappings` rows for this adapter.

export const TWOTECH_ADAPTER_KEY='2tech/busca_contrato_file'
export const TWOTECH_CONTRACT_VERSION='1.0.0'

// Fingerprints of header sets validated against a real BuscaContrato export. Empty until a real file
// is available: every schema is then reported as `unverified` (not silently trusted).
export const KNOWN_TWOTECH_SCHEMA_FINGERPRINTS:readonly string[]=[]

const STATUS_FIELDS={
 bank_client:['StatusBancoCliente'],
 company_vendor:['StatusEmpresaVendedor'],
 proposal:['StatusProposta']
} as const
const COMMISSION_FIELDS=['ComissaoRepasseValor']
// Identity aliases are provisional until validated against a real file (see CURRENT-TASK gates).
const PROPOSAL_NUMBER_FIELDS=['NumeroProposta','NrProposta','Proposta','NumeroContrato','Contrato','CodigoProposta','ADE']
const INSTITUTION_FIELDS=['Banco','NomeBanco','Instituicao','InstituicaoFinanceira']
const PRODUCER_TAX_ID_FIELDS=['CnpjProdutor','CNPJProdutor','CnpjParceiro','CNPJParceiro']
const TABLE_CODE_FIELDS=['CodigoTabela','CodTabela','Tabela']
const OPERATION_FIELDS=['Operacao','TipoOperacao','FormaContrato']
const TERM_FIELDS=['Prazo','QtdParcelas','Parcelas']
const RATE_FIELDS=['Taxa','TaxaJuros']

export const normalizeHeader=(h:string)=>h.normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^a-zA-Z0-9]/g,'').toLowerCase()

export function schemaFingerprint(headers:string[]){
 const normalized=[...new Set(headers.map(normalizeHeader).filter(Boolean))].sort()
 return createHash('sha256').update(normalized.join('|')).digest('hex')
}

export type TwoTechSchemaReport={
 fingerprint:string
 fingerprintKnown:boolean
 state:'recognized'|'quarantined'
 quarantineReason:string|null
 unmappedHeaders:string[]
}

const index=(headers:string[])=>new Map(headers.map(h=>[normalizeHeader(h),h]))
const findHeader=(idx:Map<string,string>,candidates:readonly string[])=>{
 for(const c of candidates){const h=idx.get(normalizeHeader(c));if(h!==undefined)return h}
 return null
}

export function analyzeTwoTechSchema(headers:string[]):TwoTechSchemaReport{
 const idx=index(headers)
 const fingerprint=schemaFingerprint(headers)
 const known=new Set<string>()
 const allKnown=[...PROPOSAL_NUMBER_FIELDS,...INSTITUTION_FIELDS,...PRODUCER_TAX_ID_FIELDS,...TABLE_CODE_FIELDS,...OPERATION_FIELDS,...TERM_FIELDS,...RATE_FIELDS,...COMMISSION_FIELDS,...Object.values(STATUS_FIELDS).flat()]
 for(const k of allKnown)known.add(normalizeHeader(k))
 const unmappedHeaders=headers.filter(h=>!known.has(normalizeHeader(h)))
 const hasIdentity=findHeader(idx,PROPOSAL_NUMBER_FIELDS)!==null
 const hasStatus=Object.values(STATUS_FIELDS).some(c=>findHeader(idx,c)!==null)
 const hasCommission=findHeader(idx,COMMISSION_FIELDS)!==null
 let quarantineReason:string|null=null
 if(!headers.length)quarantineReason='empty_header'
 else if(!hasIdentity)quarantineReason='missing_proposal_identity_column'
 else if(!hasStatus&&!hasCommission)quarantineReason='no_known_source_semantics_column'
 return {fingerprint,fingerprintKnown:KNOWN_TWOTECH_SCHEMA_FINGERPRINTS.includes(fingerprint),state:quarantineReason?'quarantined':'recognized',quarantineReason,unmappedHeaders}
}

const text=(v:unknown)=>v==null?null:String(v).trim()||null
const pick=(r:Record<string,unknown>,idx:Map<string,string>,candidates:readonly string[])=>{
 const h=findHeader(idx,candidates)
 return h===null?null:r[h]
}

export type CommissionState='not_reported'|'reported_zero'|'reported'|'unparseable'
export function classifyCommission(raw:unknown):{value:string|null;state:CommissionState}{
 if(raw===null||raw===undefined)return {value:null,state:'not_reported'}
 if(typeof raw==='string'&&!raw.trim())return {value:null,state:'not_reported'}
 const cleaned=typeof raw==='string'?raw.replace(/^R\$\s*/i,'').replace(/%$/,''):raw
 const value=decimalString(cleaned)
 if(value===null)return {value:null,state:'unparseable'}
 return {value,state:Number(value)===0?'reported_zero':'reported'}
}

function parseRow(r:Record<string,unknown>,rowNumber:number,idx:Map<string,string>,schema:TwoTechSchemaReport):ParsedImportRow{
 const externalProposalNumber=text(pick(r,idx,PROPOSAL_NUMBER_FIELDS))
 const commission=classifyCommission(pick(r,idx,COMMISSION_FIELDS))
 const rowQuarantine=schema.state==='quarantined'?schema.quarantineReason:!externalProposalNumber?'missing_proposal_identity':null
 const termValue=Number(pick(r,idx,TERM_FIELDS))
 const normalized:NormalizedImportRow={
  // The DB guard requires an external proposal number for record_kind 'proposal'; identity-less rows stay 'other'.
  recordKind:rowQuarantine?'other':'proposal',
  bankKey:text(pick(r,idx,INSTITUTION_FIELDS)),
  externalProposalNumber:rowQuarantine?null:externalProposalNumber,
  producerTaxId:text(pick(r,idx,PRODUCER_TAX_ID_FIELDS))?.replace(/\D/g,'')||null,
  externalTableCode:text(pick(r,idx,TABLE_CODE_FIELDS)),
  externalTableName:null,
  operationType:text(pick(r,idx,OPERATION_FIELDS)),
  term:Number.isInteger(termValue)&&termValue>0?termValue:null,
  rate:decimalString(pick(r,idx,RATE_FIELDS)),
  commissionUpfront:null,
  commissionDeferred:null,
  // Observed source values never become financial amounts here; publication needs governed evidence.
  amount:null,
  normalizedPayload:{
   ...r,
   provider_key:'2tech',
   adapter_key:TWOTECH_ADAPTER_KEY,
   contract_version:TWOTECH_CONTRACT_VERSION,
   source_status:{
    bank_client:text(pick(r,idx,STATUS_FIELDS.bank_client)),
    company_vendor:text(pick(r,idx,STATUS_FIELDS.company_vendor)),
    proposal:text(pick(r,idx,STATUS_FIELDS.proposal))
   },
   source_commission:{repasse_value:commission.value,state:commission.state,absence_of_revenue_inferred:false},
   canonicalStatus:null,
   schema:{fingerprint:schema.fingerprint,fingerprint_known:schema.fingerprintKnown,state:schema.state,unmapped_headers:schema.unmappedHeaders},
   quarantine:rowQuarantine?{reason:rowQuarantine}:null
  }
 }
 return {rowNumber,rawPayload:r,normalized}
}

export const twoTechBuscaContratoAdapter:ImportAdapter={
 key:TWOTECH_ADAPTER_KEY,
 version:TWOTECH_CONTRACT_VERSION,
 // Status and observed repasse only; commission_statement/payment semantics are deliberately not claimed.
 financialSemantic:'production_report',
 canParse:({filename})=>/\.(xlsx|xls|csv)$/i.test(filename),
 parse:({rows})=>{
  const headers=[...new Set(rows.flatMap(r=>Object.keys(r)))]
  const schema=analyzeTwoTechSchema(headers)
  const idx=index(headers)
  return rows.map((r,i)=>parseRow(r,i+1,idx,schema))
 }
}
