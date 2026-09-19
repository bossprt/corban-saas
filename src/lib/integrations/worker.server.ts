import 'server-only'
import { createAdminClient } from '@/lib/supabaseAdmin'
import type { CredentialProvider } from './contract'
import { FAKE_MANIFEST, ScriptedProvider } from './fake-provider'
import { consoleLogger } from './observability'
import { SupabaseRunRepository } from './repository'
import { localProvidersAllowed, runDispatchCycle, type CycleSummary, type ProviderFactories } from './worker'

// Server-only wiring: service role, real repository, provider factories. Never import this from a Client Component
// (the 'server-only' import above makes the build fail if someone does).
// No credential exists for any provider today; the resolver returns nothing and the fake provider yields a local, deterministic success.
const noCredentials:CredentialProvider={get:async()=>undefined}

export function buildFactories():ProviderFactories{
 // The fake is registered ONLY where local providers are allowed; resolveProvider re-checks the environment as a second lock.
 return localProvidersAllowed(process.env)?{[FAKE_MANIFEST.adapterKey]:()=>new ScriptedProvider([{kind:'success'}])}:{}
}

export function createWorkerRepository(){return new SupabaseRunRepository(createAdminClient())}

// Serverless-safe defaults: provider timeout 20s, lease 60s (must exceed the timeout), pass budget 45s (< maxDuration 60s of the route).
// A run that starts and is then killed is recovered by lease takeover after 60s and its attempt is kept in the history.
export async function dispatchOnce(opts:{limit?:number;onlyRunId?:string}={}):Promise<CycleSummary>{
 return runDispatchCycle({repo:createWorkerRepository(),factories:buildFactories(),env:process.env,credentials:noCredentials,logger:consoleLogger,limit:opts.limit,onlyRunId:opts.onlyRunId,timeoutMs:20_000,leaseSeconds:60,budgetMs:45_000})
}
