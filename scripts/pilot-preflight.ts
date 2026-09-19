// Local, read-only deployment preflight. Usage:  npm run preflight
// Reads process.env and (if present) .env.local / .env.production.local for PRESENCE checks only; never prints a value, never touches the network or the database.
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
// Node runs this file directly (type stripping), which requires the explicit .ts extension that tsc only allows with a flag we do not want app-wide.
// @ts-expect-error TS5097
import { preflight, worstLevel } from '../src/lib/preflight.ts'

const root = process.cwd()
const env: Record<string, string | undefined> = {}
for (const f of ['.env', '.env.local', '.env.production', '.env.production.local']) {
  const p = join(root, f)
  if (!existsSync(p)) continue
  for (const line of readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line)
    if (m) env[m[1]] = m[2].replace(/^['"]|['"]$/g, '')
  }
}
Object.assign(env, Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(NEXT_PUBLIC_|SUPABASE_|INTEGRATION_|CORBAN_|NODE_ENV)/.test(k))))
if (process.argv.includes('--production')) env.NODE_ENV = 'production'

const migrations = existsSync(join(root, 'supabase/migrations')) ? readdirSync(join(root, 'supabase/migrations')).filter(f => f.endsWith('.sql')) : []
const checks = preflight(env, p => existsSync(join(root, p)), process.version, migrations)
for (const c of checks) console.log(`${c.level.padEnd(7)} ${c.message}`)
const worst = worstLevel(checks)
console.log(`\nRESULT: ${worst}${worst === 'BLOCKED' ? ' (fix the BLOCKED lines before deploying)' : ''}`)
process.exit(worst === 'BLOCKED' ? 1 : 0)
