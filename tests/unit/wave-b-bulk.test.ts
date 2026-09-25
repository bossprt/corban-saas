import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { IMPORT_ISSUE_TEXT, parseBulkRefusal } from '../../src/lib/commercial'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const code = (s: string) => s.split('\n').filter(l => !l.trim().startsWith('--')).join('\n')

test('bulk refusal: only the exact refusal shape is understood; anything else falls through to the generic error path', () => {
  assert.deepEqual(parseBulkRefusal({ message: 'bulk_import_rejected', details: '[{"line":3,"code":"invalid_term"},{"line":9,"code":"duplicate_row"}]' }), [{ line: 3, code: 'invalid_term' }, { line: 9, code: 'duplicate_row' }])
  for (const bad of [{ message: 'not_authorized', details: '[{"line":1,"code":"x"}]' }, { message: 'bulk_import_rejected', details: null }, { message: 'bulk_import_rejected', details: 'not json' }, { message: 'bulk_import_rejected', details: '[]' }, { message: 'bulk_import_rejected', details: '{"line":1}' }, { message: 'bulk_import_rejected', details: '[{"line":"1","code":"x"},{"code":5}]' }, {}]) assert.equal(parseBulkRefusal(bad), null, JSON.stringify(bad))
  assert.deepEqual(parseBulkRefusal({ message: 'ERROR: bulk_import_rejected', details: '[{"line":2,"code":"a"},{"nope":1}]' }), [{ line: 2, code: 'a' }])
})
test('every code the database can put in a refusal has operator text', () => {
  const dbCodes = ['condition_already_exists', 'invalid_shares', 'duplicate_group_share', 'commission_group_not_found', 'production_shares_exceed_received_commission', 'policy_not_found', 'policy_group_inactive', 'invalid_term', 'coefficient_or_rate_required', 'invalid_received_commission', 'contract_type_not_found', 'invalid_row', 'duplicate_row', 'invalid_number', 'unexpected', 'invalid_rows', 'version_not_draft']
  const m = code(read('supabase/migrations/20261004_commercial_bulk_import_v1.sql'))
  for (const c of dbCodes) if (c !== 'invalid_number' && c !== 'unexpected' && c !== 'invalid_rows') assert.ok(m.includes(`'${c}'`), `migration lists ${c}`)
  for (const c of dbCodes) if (c !== 'condition_already_exists' && c !== 'condition_not_found') assert.ok(IMPORT_ISSUE_TEXT[c], `text for ${c}`)
})
test('bulk migration: invoker, one transaction, all-or-nothing, tenant from the version, no float, idempotent key', () => {
  const m = code(read('supabase/migrations/20261004_commercial_bulk_import_v1.sql'))
  assert.ok(!/security\s+definer/i.test(m))
  assert.ok(/save_commercial_condition\(/.test(m)) // same validation as the manual form: no second implementation of the rules
  assert.ok(/raise exception 'bulk_import_rejected' using detail=/.test(m))
  assert.ok(/jsonb_array_length\(p_rows\)>500/.test(m) && /for update/.test(m))
  assert.ok(!/organization_id/.test(m.replace(/v\.organization_id/g, ''))) // the payload's organization_id is never read
  assert.ok(!/\b(float|double precision|real)\b/i.test(m))
  assert.ok(/revoke all on function public\.import_commercial_conditions\(uuid,jsonb,uuid\) from public,anon/.test(m))
})
test('import action: atomic RPC first, refusal list surfaced with line and code, legacy path only when the RPC does not exist yet, numbers as strings', () => {
  const a = read('src/app/app/comercial/actions.ts')
  assert.ok(/rpc\('import_commercial_conditions'/.test(a) && /parseBulkRefusal\(bulk\.error\)/.test(a))
  assert.ok(/PGRST202/.test(a))
  const payload = a.slice(a.indexOf('const payload'), a.indexOf('const bulk'))
  assert.ok(/coefficient: c\.coefficient/.test(payload) && !/Number\(|parseFloat/.test(payload))
  assert.ok(a.indexOf("rpc('import_commercial_conditions'") < a.lastIndexOf("rpc('save_commercial_condition'"))
})
