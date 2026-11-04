// Bevicred webservice (manual "Documentação WEBSERVICE Bevi", 2021). Each company keeps its own credentials (partner code
// and API key) in Supabase Vault, typed by its administrator on screen (03/11/2026); they never reach the browser after
// being typed, a URL, a log or the repository.

export const BEVICRED_URL = 'https://sistema.bevicred.com.br/webserviceApi/service.php?modulo=AGENTE'

export type BevicredProbe =
  | { ok: true; ms: number }
  | { ok: false; reason: 'not_configured' | 'rejected' | 'http' | 'network' | 'timeout' | 'unexpected'; detail?: string; ms?: number }

// What Bevicred says, cleaned for the screen: one line, no more than 200 characters.
const clean = (s: unknown) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 200)

// Reads the answer of the token request. The token itself (field "dados") is never returned.
export function classifyTokenResponse(status: number, body: string, ms: number): BevicredProbe {
  if (status === 401 || status === 403) return { ok: false, reason: 'rejected', detail: `HTTP ${status}`, ms }
  if (status < 200 || status >= 300) return { ok: false, reason: 'http', detail: `HTTP ${status}`, ms }
  let json: { success?: unknown; message?: unknown; dados?: unknown } | null = null
  try { json = JSON.parse(body) } catch { return { ok: false, reason: 'unexpected', detail: 'a resposta não veio em JSON', ms } }
  if (!json || typeof json !== 'object') return { ok: false, reason: 'unexpected', ms }
  const success = json.success === true || json.success === 'true'
  if (success && typeof json.dados === 'string' && json.dados.trim().length > 0) return { ok: true, ms }
  const message = clean(json.message)
  return { ok: false, reason: 'rejected', detail: message || (success ? 'veio sem token' : 'a Bevicred recusou o acesso'), ms }
}

export const PROBE_TEXT: Record<Exclude<BevicredProbe, { ok: true }>['reason'], string> = {
  not_configured: 'Não foi possível ler o código de parceiro e a chave desta credencial.',
  rejected: 'A Bevicred recusou o acesso. Confira o código de parceiro e a chave; se estiverem certos, a Bevicred pode estar bloqueando o IP do servidor.',
  http: 'A Bevicred respondeu com erro.',
  network: 'Não foi possível falar com a Bevicred.',
  timeout: 'A Bevicred não respondeu em 15 segundos.',
  unexpected: 'A Bevicred respondeu de um jeito inesperado.',
}
