import test from 'node:test'
import assert from 'node:assert/strict'
import { movementPeriod } from '../../src/lib/finance/movements'

test('movements period: the asked days, never before the opening date, end not before start', () => {
  assert.deepEqual(movementPeriod('2026-10-01', '2026-10-07', '2026-10-06'), { from: '2026-10-06', to: '2026-10-07' })
  assert.deepEqual(movementPeriod('2026-10-07', '2026-10-08', '2026-10-06'), { from: '2026-10-07', to: '2026-10-08' })
  assert.deepEqual(movementPeriod('2026-10-09', '2026-10-08', '2026-10-06'), { from: '2026-10-09', to: '2026-10-09' })
  const d = movementPeriod('x', undefined, '2000-01-01')
  assert.match(d.from, /^\d{4}-\d{2}-01$/)
  assert.ok(d.to >= d.from)
})
