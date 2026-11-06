import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { canImportBevicred, canImportContracts, type Access, type Scope, type Tier } from '../../src/lib/access'

// Default system roles (private.ensure_default_roles), as the import sees them.
const ops = ['clientes.view', 'clientes.create', 'clientes.edit', 'leads.view', 'leads.create', 'leads.edit', 'propostas.view', 'propostas.create', 'propostas.edit', 'esteira.view', 'esteira.create', 'esteira.edit']
const role = (tier: Tier, scope: Scope, permissions: string[]): Access => ({ roleId: 'r', roleKey: 'k', roleName: 'n', tier, scope, permissions: new Set(permissions) })
const ROLES = {
  admin: role('admin', 'all', []),
  gerente: role('manager', 'branch', ops),
  supervisor: role('supervisor', 'team', [...ops, 'propostas.approve']),
  operador: role('agent', 'all', ops),
  vendedor: role('agent', 'own', ['clientes.view', 'clientes.create', 'clientes.edit', 'leads.view', 'leads.create', 'leads.edit', 'propostas.view', 'propostas.create', 'esteira.view']),
  corretor: role('agent', 'own', ['clientes.view', 'clientes.create', 'propostas.view', 'propostas.create', 'esteira.view']),
}

test('contract import: sellers and external brokers cannot import; who edits contracts can', () => {
  assert.equal(canImportContracts(ROLES.vendedor), false)
  assert.equal(canImportContracts(ROLES.corretor), false)
  for (const r of [ROLES.admin, ROLES.gerente, ROLES.supervisor, ROLES.operador]) assert.equal(canImportContracts(r), true)
  assert.equal(canImportContracts(null), false)
  assert.equal(canImportContracts(undefined), false)
})

test('Bevicred search (whole company production): admin, manager or scope "all" only', () => {
  assert.equal(canImportBevicred(ROLES.admin), true)
  assert.equal(canImportBevicred(ROLES.gerente), true)
  assert.equal(canImportBevicred(ROLES.operador), true)
  assert.equal(canImportBevicred(ROLES.supervisor), false)
  assert.equal(canImportBevicred(ROLES.vendedor), false)
  assert.equal(canImportBevicred(ROLES.corretor), false)
  // A scope "all" role without the import permissions still cannot.
  assert.equal(canImportBevicred(role('agent', 'all', ['propostas.view'])), false)
  assert.equal(canImportBevicred(null), false)
})

test('every import entry point checks the import permission on the server', () => {
  const actions = readFileSync('src/app/app/propostas/importar/actions.ts', 'utf8')
  assert.equal((actions.match(/if \(!canImportContracts\(ctx\.access\)\)/g) ?? []).length, 2, 'preview and import')
  assert.match(actions, /if \(layout\.api\) \{\s*\/\/[^\n]*\n\s*if \(!canImportBevicred\(ctx\.access\)\)/, 'Bevicred search')
  assert.match(actions, /learned\.length && canImportBevicred\(ctx\.access\)/, 'saving the Bevicred links')
  assert.match(readFileSync('src/app/app/propostas/importar/page.tsx', 'utf8'), /if \(!canImportContracts\(access\)\)/)
  assert.match(readFileSync('src/app/api/propostas/importar/modelo/route.ts', 'utf8'), /if \(!canImportContracts\(access\)\)/)
})
