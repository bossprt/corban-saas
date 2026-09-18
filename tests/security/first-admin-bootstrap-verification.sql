-- FIRST ADMIN BOOTSTRAP verification (read-only)
-- Replace :user_id only in an administrative SQL session.
select u.id,u.email,u.created_at
from auth.users u where u.id = :user_id;

select m.organization_id,m.user_id,m.role,m.status
from public.organization_memberships m where m.user_id = :user_id;

select p.id,p.organization_id,p.full_name,p.role
from public.profiles p where p.id = :user_id;

-- Expected invariant after bootstrap:
-- one active admin membership and one compatible profile for the same organization.


select pa.user_id,pa.status
from public.platform_administrators pa where pa.user_id = :platform_actor_user_id;

select e.actor_user_id,e.action,e.target_user_id,e.organization_id,e.occurred_at
from public.platform_admin_audit_events e
where e.actor_user_id=:platform_actor_user_id
  and e.target_user_id=:user_id
  and e.action='organization.bootstrap_admin'
order by e.occurred_at desc limit 1;
