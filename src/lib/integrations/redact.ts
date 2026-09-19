// Deterministic redaction for anything that can reach the run ledger, artifacts, errors or logs.
// Rules (pure, order independent, idempotent: redact(redact(x)) === redact(x)):
//  1. object keys that name credentials or sensitive banking data are replaced entirely;
//  2. string values are scanned for bearer tokens, JWTs, provider-style keys, URL credentials and `key=value` secrets;
//  3. full CPF / CNPJ numbers are masked (only the last two digits remain);
//  4. depth and size are bounded so hostile payloads cannot blow the process.
export const REDACTED='[redacted]'
const MAX_DEPTH=12
const MAX_STRING=20000

const SECRET_KEY=/^(password|passwd|senha|secret|api[_-]?key|apikey|token|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|authorization|auth|cookie|set-cookie|private[_-]?key|credentials?)$/i
const BANK_KEY=/^(agencia|agência|conta|conta[_-]?corrente|account|account[_-]?number|iban|pix|chave[_-]?pix|card[_-]?number|numero[_-]?cartao|cvv)$/i
const TAX_ID_KEY=/^(cpf|cnpj|tax[_-]?id|documento)$/i

const VALUE_PATTERNS:[RegExp,string][]=[
 [/\bbearer\s+[A-Za-z0-9._~+/=-]{8,}/gi,`Bearer ${REDACTED}`],
 [/\bbasic\s+[A-Za-z0-9+/=]{8,}/gi,`Basic ${REDACTED}`],
 [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/g,REDACTED],
 [/\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{6,}/g,REDACTED],
 [/(:\/\/[^/\s:@]+:)[^/\s@]+@/g,`$1${REDACTED}@`],
 [/\b(authorization|api[_-]?key|apikey|password|senha|secret|token|access[_-]?token|client[_-]?secret)(\s*[:=]\s*)(?!\[redacted\])[^\s"',;&]{4,}/gi,`$1$2${REDACTED}`]
]

export function maskTaxId(digits:string):string{
 const d=digits.replace(/\D/g,'')
 if(d.length!==11&&d.length!==14)return digits
 return `${'*'.repeat(d.length-2)}${d.slice(-2)}`
}

const TAX_ID_IN_TEXT=/\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b|\b\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\b/g

export function redactString(value:string):string{
 let s=value.length>MAX_STRING?value.slice(0,MAX_STRING)+'…[truncated]':value
 for(const [re,rep] of VALUE_PATTERNS)s=s.replace(re,rep)
 return s.replace(TAX_ID_IN_TEXT,m=>maskTaxId(m))
}

export function redact(value:unknown,depth=0):unknown{
 if(typeof value==='string')return redactString(value)
 if(value===null||typeof value!=='object')return value
 if(depth>=MAX_DEPTH)return '[max-depth]'
 if(Array.isArray(value))return value.slice(0,1000).map(v=>redact(v,depth+1))
 const out:Record<string,unknown>={}
 for(const [k,v] of Object.entries(value as Record<string,unknown>)){
  if(SECRET_KEY.test(k)||BANK_KEY.test(k))out[k]=REDACTED
  else if(TAX_ID_KEY.test(k)&&typeof v==='string')out[k]=maskTaxId(v)
  else out[k]=redact(v,depth+1)
 }
 return out
}

export const redactMessage=(m:unknown,max=500):string=>redactString(m instanceof Error?m.message:String(m??'')).slice(0,max)
