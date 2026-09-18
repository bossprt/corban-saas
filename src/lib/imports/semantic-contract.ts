import { assertFinancialPublicationAllowed } from './engine'
import { bevicredAdapter, daycovalAdapter, efetivaMaisAdapter } from './adapters'

export function runImportFinancialSemanticContract(){
 for(const adapter of [bevicredAdapter,daycovalAdapter,efetivaMaisAdapter]){
  if(adapter.financialSemantic!=='commercial_offer')throw new Error(`${adapter.key}: semantic drift`)
  let blocked=false
  try{assertFinancialPublicationAllowed(adapter)}catch(e){blocked=e instanceof Error&&e.message==='source_does_not_prove_financial_fact'}
  if(!blocked)throw new Error(`${adapter.key}: commercial offer could publish finance`)
 }
 return true
}
