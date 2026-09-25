-- CORBAN OS V2 — Tenant isolation gate for organization_memberships
-- Execute in a disposable/staging transaction or automated test harness.
-- This script is a specification: it must not be run against production with fabricated auth users.

-- Required assertions:
-- A. unauthenticated/anon cannot read memberships.
-- B. authenticated user A can read only A's active memberships.
-- C. user A cannot read membership rows belonging only to user B.
-- D. authenticated clients cannot INSERT/UPDATE/DELETE memberships directly.
-- E. revoked/inactive membership is not visible through the authenticated SELECT policy.
-- F. is_active_organization_member(orgA) returns true only for active membership of auth.uid().
-- G. passing another organization id never grants access without an active membership.
-- H. service/backend mutation path must separately enforce RBAC and audit; service_role bypass is not user authorization.

-- Gate result format:
-- PASS/FAIL per assertion + evidence.
-- Migration cannot be considered production-ready until all assertions pass.
