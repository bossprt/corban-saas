-- Grants hygiene, found when the local database was made to carry production's exact privileges.
--
-- 1. Five functions were still executable by anon (and PUBLIC): the second overloads of create_simulation_for_condition
--    and save_commercial_condition_range, and three write-guard trigger functions. All are SECURITY INVOKER, so RLS
--    already stopped anon; this removes the grant anyway (fail closed). Trigger functions do not need EXECUTE to fire.
-- 2. set_member_hierarchy and assign_member_access_role (F1, SECURITY INVOKER) update branch_id, team_leader_user_id,
--    scope_override and role_id, but authenticated only had column UPDATE on role, status and updated_at: in production
--    the Equipe screen could not set a member's supervisor, branch, scope or custom role. Column grants like the other
--    member RPCs fix it; row access stays with the organization_memberships_update_team policy (admin/manager) and the
--    governed-write trigger (corban.membership_rpc), so a direct API update is still refused.

revoke execute on function public.create_simulation_for_condition(uuid, uuid, uuid, numeric, integer, numeric) from public, anon;
revoke execute on function public.save_commercial_condition_range(uuid, uuid, integer, integer, numeric, numeric, numeric, jsonb, uuid, uuid, numeric, numeric) from public, anon;
revoke execute on function public.guard_admin_event_write() from public, anon;
revoke execute on function public.guard_invitation_write() from public, anon;
revoke execute on function public.guard_membership_write() from public, anon;

grant update (branch_id, team_leader_user_id, scope_override, role_id) on public.organization_memberships to authenticated;
