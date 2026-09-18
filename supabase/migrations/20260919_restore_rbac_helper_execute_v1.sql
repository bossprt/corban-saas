-- PREPARED, NOT APPLIED (Human Gate: privilege change on production). CRITICAL for real users.
-- 20260918_rbac_helper_exposure_patch revoked EXECUTE on public.has_active_organization_role from `authenticated`.
-- The function is SECURITY DEFINER, but its callers are not: every RLS policy and SECURITY INVOKER RPC that
-- calls it is evaluated with the caller's privileges, so ALL role-gated writes fail for real users with
--   ERROR 42501: permission denied for function has_active_organization_role
-- (reproduced inside a rolled-back transaction: insert into commercial_entities as an authenticated admin;
--  publish_financial_reversal; the live financial_events insert policy, rule publishers, reconciliation, etc.).
-- The live database currently has 0 auth users, so this was never exercised end to end.
-- Restoring EXECUTE for authenticated only lets a caller ask "do I hold role X in organization Y?" about
-- THEMSELVES (auth.uid() is read inside; no argument selects another user), so it is not a data leak.
-- anon and PUBLIC stay revoked. Tradeoff: Supabase's advisor may flag an authenticated-executable SECURITY
-- DEFINER function (WARN). The cleaner long-term design (debt B) is a non-exposed `private` schema for helpers.
grant execute on function public.has_active_organization_role(uuid,text[]) to authenticated;
revoke execute on function public.has_active_organization_role(uuid,text[]) from public,anon;
