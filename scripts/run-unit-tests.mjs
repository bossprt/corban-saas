// Dependency-free unit test runner: compile with the repo TypeScript, run with node:test.
import { execFileSync } from 'node:child_process'
import { rmSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const root = process.cwd()
const out = join(root, '.test-build')
rmSync(out, { recursive: true, force: true })
const tsc = join(root, 'node_modules', 'typescript', 'bin', 'tsc')
execFileSync(process.execPath, [tsc, '-p', 'tests/unit/tsconfig.json'], { stdio: 'inherit' })
const testDir = join(out, 'tests', 'unit')
const files = readdirSync(testDir).filter(f => f.endsWith('.test.js')).map(f => join(testDir, f))
execFileSync(process.execPath, ['--test','--test-reporter=spec', ...files], { stdio: 'inherit' })
