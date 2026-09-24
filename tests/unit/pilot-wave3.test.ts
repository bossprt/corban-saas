import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { FEEDBACK, classifyDbFeedback, feedbackTone, feedbackUrl, isFeedbackCode } from '../../src/lib/feedback'
import { checkUpload, safeFileName, sniffDocumentMime } from '../../src/lib/documents'
import { isValidCpf, maskCpf } from '../../src/lib/cpf'
import { digitsOnly, searchTerm } from '../../src/lib/search'
import { proposalStatusLabel } from '../../src/lib/operational'

const read = (p: string) => readFileSync(join(process.cwd(), p), 'utf8')
const bytes = (...n: number[]) => Uint8Array.from([...n, ...new Array(Math.max(0, 16 - n.length)).fill(0)])
const PDF = bytes(0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34)
const PNG = bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
const JPG = bytes(0xff, 0xd8, 0xff, 0xe0)
const WEBP = Uint8Array.from([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50, 0, 0, 0, 0])

// ---- feedback: whitelist only
test('feedback: only whitelisted codes render; tone is derived; URLs carry codes, never text', () => {
  assert.ok(isFeedbackCode('ok:lead_registrado') && isFeedbackCode('erro:cpf_invalido'))
  for (const bad of ['', 'erro:<script>', 'ok:lead_registrado ', '__proto__', 'constructor', 'erro:PGRST202', null, undefined, 5]) assert.equal(isFeedbackCode(bad), false, String(bad))
  assert.equal(feedbackTone('ok:doc_enviado'), 'ok')
  assert.equal(feedbackTone('erro:doc_grande'), 'erro')
  assert.equal(feedbackUrl('/app/leads', 'erro:nome_invalido'), '/app/leads?f=erro%3Anome_invalido')
})
test('feedback: no message exposes technical vocabulary', () => {
  for (const m of Object.values(FEEDBACK)) assert.doesNotMatch(m, /PGRST|Postgrest|SQLSTATE|23505|42501|\bRLS\b|\bRPC\b|stack|uuid|select |insert /i, m)
})
test('feedback: database errors map to codes without leaking their text', () => {
  assert.equal(classifyDbFeedback({ code: '23505', message: 'duplicate key value violates unique constraint "clients_cpf"' }), 'erro:cpf_duplicado')
  assert.equal(classifyDbFeedback({ code: 'PGRST202', message: 'x' }), 'erro:indisponivel')
  assert.equal(classifyDbFeedback({ code: '42501', message: 'permission denied for table leads' }), 'erro:sem_permissao')
  assert.equal(classifyDbFeedback({ message: 'lead_forbidden' }), 'erro:sem_permissao')
  assert.equal(classifyDbFeedback({ message: 'anything else SELECT * FROM x' }), 'erro:inesperado')
  assert.equal(classifyDbFeedback(null), 'erro:inesperado')
})
test('pilot actions redirect with codes instead of throwing raw errors', () => {
  for (const f of ['src/app/app/leads/actions.ts', 'src/app/app/clientes/actions.ts', 'src/app/app/simulacoes/actions.ts', 'src/app/app/documentos/actions.ts']) {
    const s = read(f)
    assert.doesNotMatch(s, /throw new Error/, f)
    assert.match(s, /feedbackUrl/, f)
  }
  const p = read('src/app/app/propostas/[id]/actions.ts')
  const pilotPart = p.slice(p.indexOf('export async function prepareDocuments'), p.indexOf('export async function publishExpectedCommission'))
  assert.doesNotMatch(pilotPart, /throw new Error/)
})
test('the app shell shows the banner and the error boundary never prints the raw message', () => {
  assert.match(read('src/app/app/layout.tsx'), /<FlashBanner \/>/)
  const e = read('src/app/app/error.tsx')
  assert.doesNotMatch(e, /error\.message/)
  assert.match(e, /Referência/)
})
test('FlashBanner renders text only from the whitelist', () => {
  const b = read('src/components/FlashBanner.tsx')
  assert.match(b, /isFeedbackCode\(code\)/)
  assert.doesNotMatch(b, /dangerouslySetInnerHTML/)
})

// ---- uploads: real type, size, names
test('upload sniffing: accepts real PDF/JPEG/PNG/WebP, refuses everything else', () => {
  assert.equal(sniffDocumentMime(PDF), 'application/pdf')
  assert.equal(sniffDocumentMime(PNG), 'image/png')
  assert.equal(sniffDocumentMime(JPG), 'image/jpeg')
  assert.equal(sniffDocumentMime(WEBP), 'image/webp')
  const enc = (s: string) => new TextEncoder().encode(s.padEnd(20, ' '))
  for (const bad of ['<html><script>alert(1)</script>', '<?xml version="1.0"?><svg onload="x">', 'MZ\u0000\u0003 executable', '#!/bin/sh\nrm -rf /', 'GIF89a......']) assert.equal(sniffDocumentMime(enc(bad)), null, bad)
  assert.equal(sniffDocumentMime(new Uint8Array(0)), null)
  assert.equal(sniffDocumentMime(new Uint8Array(5)), null)
})
test('upload check: empty, oversize, disguised and mismatching files are refused with a code', () => {
  assert.deepEqual(checkUpload(PDF.length, 'application/pdf', PDF), { ok: true, mime: 'application/pdf' })
  assert.deepEqual(checkUpload(0, 'application/pdf', new Uint8Array(0)), { ok: false, code: 'erro:doc_vazio' })
  assert.deepEqual(checkUpload(5 * 1024 * 1024, 'application/pdf', PDF), { ok: false, code: 'erro:doc_grande' })
  const html = new TextEncoder().encode('<html><body>fake</body></html>')
  assert.deepEqual(checkUpload(html.length, 'application/pdf', html), { ok: false, code: 'erro:doc_formato' }) // HTML renamed .pdf
  assert.deepEqual(checkUpload(PNG.length, 'application/pdf', PNG), { ok: false, code: 'erro:doc_formato' })      // declared != real
  assert.deepEqual(checkUpload(PNG.length, 'image/svg+xml', PNG), { ok: false, code: 'erro:doc_formato' })
  assert.deepEqual(checkUpload(PDF.length, '', PDF), { ok: false, code: 'erro:doc_formato' })
})
test('file names: no traversal, separators, control or non-ASCII characters', () => {
  for (const n of ['../../etc/passwd', '..\\..\\windows\\system32', 'a/b/c.pdf', 'nome\u0000.pdf', '<script>.pdf', 'certidão de nascimento.pdf', '....', '']) {
    const s = safeFileName(n)
    assert.doesNotMatch(s, /[\\/\u0000-\u001f<>]/, n)
    assert.doesNotMatch(s, /\.\./, n)
    assert.ok(s.length > 0 && s.length <= 120)
    assert.doesNotMatch(s, /^[.-]/, n)
  }
  assert.equal(safeFileName('x'.repeat(500) + '.pdf').length, 120)
})
test('upload action decides on the real bytes before touching the database or storage', () => {
  const a = read('src/app/app/documentos/actions.ts')
  assert.ok(a.indexOf('checkUpload') < a.indexOf(".from('clients')"))
  assert.ok(a.indexOf('checkUpload') < a.indexOf('storage'))
  assert.match(a, /contentType: check\.mime/)
})

// ---- CPF / search / PII in URLs
test('cpf: check digits, masking', () => {
  assert.equal(isValidCpf('52998224725'), true)
  for (const bad of ['11111111111', '12345678900', '5299822472', '529982247255', 'abcdefghijk', '']) assert.equal(isValidCpf(bad), false, bad)
  assert.equal(maskCpf('52998224725'), '***.982.247-**')
  assert.equal(maskCpf(null), '—')
  assert.equal(maskCpf('123'), '***.***.***-**')
})
test('search: filter-language characters are stripped; short terms ignored; CPF is never a search key', () => {
  assert.equal(searchTerm('  Ana  Souza '), 'Ana Souza')
  assert.equal(searchTerm('a,b(c)%_*"x'), 'a b c x')
  assert.equal(searchTerm('a'), null)
  assert.equal(searchTerm(undefined), null)
  assert.equal(searchTerm(['ana', 'x']), 'ana')
  assert.ok((searchTerm('x'.repeat(200)) ?? '').length <= 60)
  assert.equal(digitsOnly('(11) 99999-0000'), '11999990000')
  for (const f of ['src/app/app/leads/page.tsx', 'src/app/app/clientes/page.tsx']) assert.doesNotMatch(read(f), /cpf\.(ilike|eq)|\.eq\('cpf'/i, f)
})
test('no page or action puts a CPF in a URL', () => {
  for (const f of ['src/app/app/leads/actions.ts', 'src/app/app/clientes/actions.ts']) assert.doesNotMatch(read(f), /feedbackUrl\([^)]*cpf|redirect\([^)]*cpf/i, f)
})

// ---- labels, nulls, navigation
test('proposal statuses have labels and a next step; paid is evidence-only', () => {
  for (const s of ['draft', 'documents_pending', 'ready_for_digitization', 'digitization', 'submitted', 'approved', 'rejected', 'cancelled', 'paid']) assert.ok(proposalStatusLabel(s).label && proposalStatusLabel(s).next, s)
  assert.equal(proposalStatusLabel('zzz').label, 'Situação desconhecida')
  assert.match(proposalStatusLabel('paid').label, /evidência/)
})
test('unknown money is "Não calculado", never R$ 0,00', () => {
  for (const f of ['src/app/app/simulacoes/page.tsx', 'src/app/app/propostas/[id]/page.tsx']) assert.match(read(f), /value === null \? 'Não calculado'/, f)
})
test('menu: modules are role-aware (F1 journey navigation: 8 entries)', () => {
  const NL = String.fromCharCode(10)
  const l = read('src/app/app/layout.tsx')
  for (const [href, guard] of [['/app/financeiro', 'canViewCommission'], ['/app/comercial', "atLeast(r, 'supervisor')"], ['/app/configuracao', 'canManageTeam']]) {
    const line = l.split(NL).find(x => x.includes(`'${href}'`)) ?? ''
    assert.ok(line.includes(guard), href)
  }
  for (const href of ['/app', '/app/hoje', '/app/clientes', '/app/propostas', '/app/relatorios']) assert.ok(!(l.split(NL).find(x => x.includes(`'${href}',`)) ?? '').includes('show:'), href)
})
test('agent dashboard is scoped to the agent own records', () => {
  const d = read('src/app/app/page.tsx')
  assert.match(d, /const mine = membership\.role === 'agent'/)
  assert.match(d, /Meus leads em aberto/)
  assert.match(d, /Minhas propostas/)
  assert.match(d, /eq\('created_by', user\.id\)/)
})
test('the simulation page guides an empty organization and never shows a table UUID', () => {
  const s = read('src/app/app/simulacoes/page.tsx')
  assert.match(s, /Nenhuma tabela comercial publicada/)
  assert.doesNotMatch(s, /product_table_id\.slice/)
})
test('submit buttons disable themselves while pending on the main forms', () => {
  for (const f of ['src/app/app/leads/page.tsx', 'src/app/app/clientes/page.tsx', 'src/app/app/simulacoes/page.tsx', 'src/app/app/documentos/page.tsx']) assert.match(read(f), /<SubmitButton/, f)
  assert.match(read('src/components/SubmitButton.tsx'), /useFormStatus/)
})

test('permission catalog in the app matches the database catalog', async () => {
  const { MODULES, ACTIONS } = await import('../../src/lib/access')
  const m = read('supabase/migrations/20260924071259_organization_roles_permissions_v1.sql')
  const mods = /unnest\(array\[([^\]]+)\]\) m/.exec(m)?.[1].replace(/'/g, '').split(',').map(s => s.trim())
  const acts = /unnest\(array\[([^\]]+)\]\) a/.exec(m)?.[1].replace(/'/g, '').split(',').map(s => s.trim())
  assert.deepEqual(mods, [...MODULES])
  assert.deepEqual(acts, [...ACTIONS])
})
test('team errors pick the most specific code', async () => {
  const { classifyTeamError } = await import('../../src/lib/team')
  assert.equal(classifyTeamError({ message: 'invalid_role_name' }), 'invalid_role_name')
  assert.equal(classifyTeamError({ message: 'invalid_role' }), 'invalid_role')
  assert.equal(classifyTeamError({ message: 'role_in_use' }), 'role_in_use')
})
test('access check fails closed', async () => {
  const { can } = await import('../../src/lib/access')
  assert.equal(can(null, 'clientes.view'), false)
  assert.equal(can({ roleId: 'x', roleKey: 'vendedor', roleName: 'Vendedor', tier: 'agent', scope: 'own', permissions: new Set(['clientes.view']) }, 'clientes.view'), true)
  assert.equal(can({ roleId: 'x', roleKey: 'vendedor', roleName: 'Vendedor', tier: 'agent', scope: 'own', permissions: new Set(['clientes.view']) }, 'repasse.approve'), false)
})
test('plan module catalog in the app matches the database catalog', async () => {
  const { PLAN_MODULES } = await import('../../src/lib/access')
  const m = read('supabase/migrations/20260924114956_organization_modules_v1.sql')
  const body = /select array\[([^\]]+)\]/.exec(m)?.[1] ?? ''
  assert.deepEqual(body.replace(/'/g, '').split(',').map(s => s.trim()), [...PLAN_MODULES])
})
test('platform module switch is gated, validated and audited', () => {
  const a = read('src/app/platform/actions.ts')
  const fn = a.slice(a.indexOf('export async function setOrganizationModule'))
  assert.match(fn, /await gate\(\)/)
  assert.match(fn, /isPlanModule\(moduleKey\)/)
  assert.match(fn, /platform_admin_audit_events/)
})
test('client registration goes through the identity rule and never puts the CPF in a URL', () => {
  const a = read('src/app/app/clientes/actions.ts')
  assert.match(a, /rpc\('upsert_client'/)
  assert.doesNotMatch(a, /from\('clients'\)\s*\.insert/)
  assert.doesNotMatch(a, /feedbackUrl\([^)]*cpf/i)
  assert.doesNotMatch(read('src/app/app/clientes/page.tsx'), /q=.*cpf|cpf.*searchParams/i)
})
test('CPF and phone formatting', async () => {
  const { formatCpf, formatPhone } = await import('../../src/lib/cpf')
  assert.equal(formatCpf('52998224725'), '529.982.247-25')
  assert.equal(formatPhone('5568999000101'), '(68) 99900-0101')
  assert.equal(formatPhone('6832240000'), '(68) 3224-0000')
})
test('public API route authenticates only through the database and logs nothing from the request', () => {
  const r = read('src/app/api/v1/leads/route.ts')
  assert.match(r, /rpc\('api_ingest_lead'/)
  assert.doesNotMatch(r, /console\.(log|info|warn|error)/)
  assert.doesNotMatch(r, /organization_id|p_org/)
  const a = read('src/app/app/configuracao/api/actions.ts')
  assert.doesNotMatch(a, /redirect\(|console\./)
})
