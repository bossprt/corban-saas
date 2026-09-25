import test from 'node:test'
import assert from 'node:assert/strict'
import { atLeast } from '../../src/lib/rbac'

test('role hierarchy is monotonic: agent < supervisor < manager < admin',()=>{
 assert.equal(atLeast('agent','supervisor'),false)
 assert.equal(atLeast('supervisor','supervisor'),true)
 assert.equal(atLeast('supervisor','manager'),false)
 assert.equal(atLeast('manager','manager'),true)
 assert.equal(atLeast('manager','supervisor'),true)
 assert.equal(atLeast('admin','manager'),true)
 assert.equal(atLeast('admin','agent'),true)
})

test('unknown, empty, null or prototype-key roles are denied (fail closed)',()=>{
 for(const r of [undefined,null,'','owner','ADMIN','root','__proto__','constructor','toString','hasOwnProperty'])assert.equal(atLeast(r as string|null|undefined,'agent'),false,String(r))
})
