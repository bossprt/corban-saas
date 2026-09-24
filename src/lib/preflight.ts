// Deployment preflight (pure). Takes an environment-like object and a file-existence probe and returns PASS / WARN / BLOCKED lines.
// It only ever looks at PRESENCE and SHAPE of values; it never returns a value, so its output is safe to paste anywhere.
export type Level = 'PASS' | 'WARN' | 'BLOCKED'
export type Check = { level: Level; message: string }

type Env = Record<string, string | undefined>
const has = (e: Env, k: string) => (e[k] ?? '').trim().length > 0
const isHttpUrl = (v: string | undefined) => { try { const u = new URL(v ?? ''); return u.protocol === 'https:' || u.protocol === 'http:' } catch { return false } }

export const REQUIRED_FILES = ['package.json', 'next.config.ts', 'proxy.ts', 'src/app/api/health/route.ts', 'src/app/auth/confirm/route.ts', 'src/app/auth/definir-senha/page.tsx', 'src/app/login/recuperar/page.tsx', 'src/app/api/admin/organizations/route.ts', 'src/app/api/admin/reference-catalog/route.ts']

export function preflight(env: Env, fileExists: (p: string) => boolean, nodeVersion: string, migrations: string[] = []): Check[] {
  const out: Check[] = []
  const add = (level: Level, message: string) => out.push({ level, message })
  const production = env.NODE_ENV === 'production'

  // ---- required for ANY operator to work
  if (isHttpUrl(env.NEXT_PUBLIC_SUPABASE_URL)) add('PASS', 'NEXT_PUBLIC_SUPABASE_URL is a valid URL'); else add('BLOCKED', 'NEXT_PUBLIC_SUPABASE_URL missing or not a URL')
  if (has(env, 'NEXT_PUBLIC_SUPABASE_ANON_KEY')) add('PASS', 'NEXT_PUBLIC_SUPABASE_ANON_KEY defined'); else add('BLOCKED', 'NEXT_PUBLIC_SUPABASE_ANON_KEY missing (login and every page fail)')
  if (has(env, 'SUPABASE_SERVICE_ROLE_KEY')) add('PASS', 'SUPABASE_SERVICE_ROLE_KEY defined (server-only)'); else add('BLOCKED', 'SUPABASE_SERVICE_ROLE_KEY missing (invitations, team, organization bootstrap fail)')
  if (env.SUPABASE_SERVICE_ROLE_KEY && env.NEXT_PUBLIC_SUPABASE_ANON_KEY && env.SUPABASE_SERVICE_ROLE_KEY === env.NEXT_PUBLIC_SUPABASE_ANON_KEY) add('BLOCKED', 'service role key equals the public key: wrong value pasted')

  // ---- public origin
  if (!has(env, 'NEXT_PUBLIC_SITE_URL')) add(production ? 'BLOCKED' : 'WARN', 'NEXT_PUBLIC_SITE_URL missing (invitation and recovery links need an explicit origin in production)')
  else if (!isHttpUrl(env.NEXT_PUBLIC_SITE_URL)) add('BLOCKED', 'NEXT_PUBLIC_SITE_URL is not a valid URL')
  else {
    const u = new URL(env.NEXT_PUBLIC_SITE_URL as string)
    if (u.pathname !== '/' || u.search || u.hash) add('BLOCKED', 'NEXT_PUBLIC_SITE_URL must be an origin only (no path, query or fragment)')
    else if (production && u.protocol !== 'https:') add('BLOCKED', 'NEXT_PUBLIC_SITE_URL must be https in production')
    else add('PASS', 'NEXT_PUBLIC_SITE_URL is a valid origin')
  }

  // ---- worker (does NOT block the first operator)
  if (!has(env, 'INTEGRATION_WORKER_SECRET')) add('WARN', 'INTEGRATION_WORKER_SECRET absent: worker dispatch is disabled (not needed for the first operator)')
  else if ((env.INTEGRATION_WORKER_SECRET ?? '').length < 24) add('WARN', 'INTEGRATION_WORKER_SECRET shorter than 24 characters: the dispatch route stays disabled')
  else add('PASS', 'INTEGRATION_WORKER_SECRET present and long enough')
  if (production && env.CORBAN_ALLOW_LOCAL_PROVIDERS === '1') add('WARN', 'CORBAN_ALLOW_LOCAL_PROVIDERS=1 in production is ignored by the code, but remove it')
  if (has(env, 'NEXT_PUBLIC_INTEGRATION_WORKER_SECRET') || has(env, 'NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY')) add('BLOCKED', 'a server secret is exposed through a NEXT_PUBLIC_ variable')

  // ---- runtime / files
  const major = Number(nodeVersion.replace(/^v/, '').split('.')[0])
  if (major >= 20) add('PASS', `Node ${nodeVersion} is supported (>= 20)`); else add('BLOCKED', `Node ${nodeVersion} is too old (need >= 20)`)
  for (const f of REQUIRED_FILES) if (!fileExists(f)) add('BLOCKED', `required file missing: ${f}`)
  if (REQUIRED_FILES.every(fileExists)) add('PASS', 'all required routes and config files exist')
  if (fileExists('vercel.json')) add('WARN', 'vercel.json exists: review it (none is needed)')
  if (migrations.length) add('PASS', `${migrations.length} migration files in the repository (compare with the LIVE list from list_migrations; never applied by this script)`)
  return out
}

export const worstLevel = (c: Check[]): Level => (c.some(x => x.level === 'BLOCKED') ? 'BLOCKED' : c.some(x => x.level === 'WARN') ? 'WARN' : 'PASS')
