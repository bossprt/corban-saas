import { localProvidersAllowed } from './worker'
import { PROVIDER_REGISTRY, usability } from './registry'

// Worker readiness as an operator sees it. Pure: takes an env-like object, returns booleans and provider KEYS only
// (never values of secrets, never connection strings). This is BUSINESS readiness; app liveness lives in /api/health.
export type ProviderEnvironment='local_test'|'real'|'not_homologated'

export type WorkerReadiness={
 secretConfigured:boolean          // INTEGRATION_WORKER_SECRET present and strong enough for the dispatch route to answer
 localProvidersAllowed:boolean     // fake providers may run (development/test + explicit flag), never in production
 runnableProviders:string[]        // adapter keys the worker can actually execute right now
 realProviderAvailable:boolean
 notes:string[]
}

// Same rule as authorizeWorkerRequest: shorter than 24 characters means the route stays disabled.
const MIN_SECRET=24

export function providerEnvironment(adapterKey:string):ProviderEnvironment{
 const e=PROVIDER_REGISTRY.find(x=>x.manifest.adapterKey===adapterKey)
 if(!e)return 'not_homologated'
 if(e.homologation==='local_only')return 'local_test'
 return usability(adapterKey).usable?'real':'not_homologated'
}

export const ENVIRONMENT_LABEL:Record<ProviderEnvironment,string>={
 local_test:'LOCAL / TESTE - não é banco',
 real:'PROVEDOR REAL',
 not_homologated:'NÃO HOMOLOGADO'
}

export function workerReadiness(env:Record<string,string|undefined>):WorkerReadiness{
 const secretConfigured=(env.INTEGRATION_WORKER_SECRET??'').length>=MIN_SECRET
 const local=localProvidersAllowed(env)
 const runnable=PROVIDER_REGISTRY.filter(e=>usability(e.manifest.adapterKey).usable&&(e.homologation!=='local_only'||local)).map(e=>e.manifest.adapterKey)
 const realProviderAvailable=runnable.some(k=>providerEnvironment(k)==='real')
 const notes:string[]=[]
 if(!secretConfigured)notes.push('Disparo do worker desativado: falta INTEGRATION_WORKER_SECRET (24+ caracteres) no servidor.')
 if(!realProviderAvailable)notes.push('Nenhum provedor real está homologado: execuções só podem rodar contra provedores locais de teste.')
 if(!local)notes.push('Provedores locais de teste estão bloqueados neste ambiente.')
 notes.push('O sistema não consegue detectar se um agendador externo está configurado.')
 return {secretConfigured,localProvidersAllowed:local,runnableProviders:runnable,realProviderAvailable,notes}
}
