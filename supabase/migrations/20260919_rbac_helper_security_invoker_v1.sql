-- PREPARED, NOT APPLIED (Human Gate: replaces a live function; same signature, same results).
-- Goal: remove the Security Advisor WARN "SECURITY DEFINER function executable by authenticated" for
-- public.has_active_organization_role WITHOUT weakening tenant isolation or rewriting 36 policies + 10 functions.
--
-- Why SECURITY DEFINER is unnecessary here:
--  * The only reason to keep it was RLS recursion safety. organization_memberships has exactly ONE policy,
--    organization_memberships_select_self: (user_id = (select auth.uid())) AND (status = 'active'), which does not call
--    the helper, so there is no recursion.
--  * The helper only asks about the CALLER's own active membership (user_id = auth.uid(), status='active'). Those are
--    exactly the rows RLS already lets the caller read, so running it as the caller (SECURITY INVOKER) returns the same
--    boolean for every input. public.is_active_organization_member (78 policies) already uses this pattern.
-- Dependencies were enumerated live (36 policies on 21 tables, 10 public functions; no views/triggers) and all bind by
-- OID/name to the SAME signature, so CREATE OR REPLACE keeps them working. No client can ask about another user: the
-- function has no user argument and auth.uid() comes from the JWT.
create or replace function public.has_active_organization_role(p_organization_id uuid, p_roles text[])
returns boolean
language sql
stable
security invoker
set search_path to ''
as $function$
  select exists (
    select 1 from public.organization_memberships m
    where m.organization_id=p_organization_id
      and m.user_id=(select auth.uid())
      and m.status='active'
      and m.role=any(p_roles)
  );
$function$;

revoke all on function public.has_active_organization_role(uuid,text[]) from public,anon;
grant execute on function public.has_active_organization_role(uuid,text[]) to authenticated;
