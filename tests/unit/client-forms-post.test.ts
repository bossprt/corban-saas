import test from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

// A form sent by JavaScript (onSubmit) must say method="post": if it is submitted before the page finishes loading, the
// browser sends it by itself, and without the method it goes as GET, with every field (password, CPF) in the address
// (found 09/10/2026 on the login form). A list filter that is meant to be a GET (the search boxes) says method="get".
const files = (dir: string): string[] => readdirSync(dir).flatMap(n => {
  const p = join(dir, n)
  return statSync(p).isDirectory() ? files(p) : p.endsWith('.tsx') ? [p] : []
})

test('every form submitted by JavaScript is a POST', () => {
  const bad = files('src').filter(f => /<form(?![^>]*method=)[^>]*onSubmit=/.test(readFileSync(f, 'utf8')))
  assert.deepEqual(bad, [])
})
