-- CORBAN OS — Organization direct-write privilege hardening V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Tenant users read organizations through RLS; creation/bootstrap remains platform-governed.

revoke insert, update, delete on table public.organizations from authenticated;
revoke insert, update, delete on table public.organizations from anon;
