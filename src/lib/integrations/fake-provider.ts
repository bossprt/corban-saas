import type { CapabilityManifest, ProviderAdapter, ProviderCall, ProviderContext } from './contract'

// Local deterministic provider with the SAME contract real providers will use. No network, no credentials. Every step of the script
// is one provider behaviour, so the whole path request -> executor -> repository -> adapter -> response -> evidence -> final state
// runs for real in tests.
export type FakeStep=
 |{kind:'success';externalRequestId?:string}
 |{kind:'delayed';delayMs:number;externalRequestId?:string}
 |{kind:'duplicate';externalRequestId:string}          // same success again (provider replays its answer)
 |{kind:'timeout'}                                      // never answers until aborted
 |{kind:'transient';code?:string}                       // retryable failure
 |{kind:'permanent';code?:string}                       // terminal failure
 |{kind:'malformed';shape:'not_object'|'no_ok'|'no_artifacts'|'no_response_evidence'|'bad_kind'}
 |{kind:'throws';message:string}
 |{kind:'leaky';externalRequestId?:string}              // success whose payload carries secrets (must be redacted before persistence)

export const FAKE_MANIFEST:CapabilityManifest={
 provider:'local',adapterKey:'local/fake',contractVersion:'1.0.0',transport:'api',external:false,
 capabilities:{
  submit:{idempotent:true,mode:'sync',mutating:true},
  status:{idempotent:true,mode:'sync',mutating:false},
  proposal_lookup:{idempotent:true,mode:'sync',mutating:false},
  contract_lookup:{idempotent:true,mode:'sync',mutating:false},
  simulation:{idempotent:true,mode:'sync',mutating:false},
  cancel:{idempotent:true,mode:'sync',mutating:true}
 }
}

// A file-oriented provider does not support every operation: capability discovery, not provider-name checks, drives behaviour.
export const FAKE_FILE_MANIFEST:CapabilityManifest={
 provider:'local',adapterKey:'local/fake_file',contractVersion:'1.0.0',transport:'file',external:false,
 capabilities:{status:{idempotent:true,mode:'async',mutating:false},contract_lookup:{idempotent:true,mode:'async',mutating:false}}
}

const ok=(id:string,extra:Record<string,unknown>={})=>({ok:true,externalRequestId:id,artifacts:[{kind:'response_metadata',payload:{accepted:true,providerRef:id,...extra}}]})

export class ScriptedProvider implements ProviderAdapter{
 readonly calls:{call:ProviderCall;attempt:number;correlationId:string}[]=[]
 constructor(private readonly script:FakeStep[]=[{kind:'success'}],readonly manifest:CapabilityManifest=FAKE_MANIFEST){}
 async execute(call:ProviderCall,ctx:ProviderContext):Promise<unknown>{
  const step=this.script[Math.min(this.calls.length,this.script.length-1)]
  this.calls.push({call,attempt:ctx.attempt,correlationId:ctx.correlationId})
  // The fake never needs credentials; resolving one proves the executor hands a working CredentialProvider without persisting it.
  switch(step.kind){
   case'success':return ok(step.externalRequestId??`fake-${call.idempotencyKey.slice(0,8)}`)
   case'duplicate':return ok(step.externalRequestId)
   case'delayed':await new Promise(r=>setTimeout(r,step.delayMs));return ok(step.externalRequestId??`fake-${call.idempotencyKey.slice(0,8)}`)
   case'timeout':return new Promise((_,rej)=>{ctx.signal.addEventListener('abort',()=>rej(new Error('aborted')))})
   case'transient':return {ok:false,retryable:true,code:step.code??'provider_unavailable',message:'temporary provider failure'}
   case'permanent':return {ok:false,retryable:false,code:step.code??'rejected_by_provider',message:'provider refused the request'}
   case'throws':throw new Error(step.message)
   case'leaky':return {ok:true,externalRequestId:step.externalRequestId??'leaky-1',artifacts:[{kind:'response_metadata',payload:{accepted:true,headers:{Authorization:'Bearer abcdef0123456789abcdef',cookie:'sid=1'},api_key:'sk_live_abcdef123456',note:'cpf 12345678901 token=abcd1234efgh'}},{kind:'diagnostic',payload:{url:'https://user:hunter2pass@example.test/x'}}]}
   case'malformed':
    switch(step.shape){
     case'not_object':return 'ok'
     case'no_ok':return {externalRequestId:'x'}
     case'no_artifacts':return {ok:true,externalRequestId:'x',artifacts:[]}
     case'no_response_evidence':return {ok:true,externalRequestId:'x',artifacts:[{kind:'diagnostic',payload:{}}]}
     case'bad_kind':return {ok:true,externalRequestId:'x',artifacts:[{kind:'financial_truth',payload:{}}]}
    }
  }
 }
}
