-- CORBAN OS V2 — RBAC helper exposure corrective patch.
-- Keep SECURITY DEFINER for RLS recursion safety, but remove direct API EXECUTE.
revoke all on function public.has_active_organization_role(uuid,text[]) from public,anon,authenticated;
