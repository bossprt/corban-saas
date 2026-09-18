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
