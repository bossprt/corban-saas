-- Contract test for 20261008_caller_role_null_check_v1: an administrator of another company cannot change company A's
-- lead distribution, a member's "receives leads", a seller's goal, a pipeline stage or the payout settings (all refused
-- with not_authorized, nothing changes); company A's own administrator still can. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/caller-role-null-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000b0b01'::uuid as org_b,
       '00000000-0000-4000-8000-0000000b0b02'::uuid as admin_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Papel', 'papel-' || gen_random_uuid(), 'starter', true from ids;
insert into auth.users (id, email, aud, role) select admin_b, 'admin.b@papel.local', 'authenticated', 'authenticated' from ids;
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status) select org_b, admin_b, 'admin', 'active' from ids;
select set_config('corban.membership_rpc', 'off', true);

create temp table a as
select (select id from public.organization_memberships where organization_id = (select org_a from ids) and user_id <> (select admin_a from ids) order by created_at limit 1) as membership,
       (select id from public.operational_stages where organization_id = (select org_a from ids) order by sort_order limit 1) as stage,
       (select user_id from public.organization_memberships where organization_id = (select org_a from ids) and role = 'agent' limit 1) as seller_user;
grant select on a to authenticated;
create temp table before as
select (select receives_leads from public.organization_memberships where id = (select membership from a)) as receives,
       (select to_jsonb(s) from public.operational_stages s where id = (select stage from a)) as stage,
       (select count(*) from public.seller_goals where organization_id = (select org_a from ids)) as goals,
       (select to_jsonb(o) - 'updated_at' from public.organizations o where id = (select org_a from ids)) as org;
grant select on before to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', (select admin_b from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'B cannot change A''s lead distribution',
  pg_temp.err(format('select public.set_lead_distribution(%L, %L)', (select org_a from ids), 'manual')) like '%not_authorized%';
insert into results select 'B cannot change whether an A member receives leads',
  pg_temp.err(format('select public.set_member_receives_leads(%L, %L)', (select membership from a), not coalesce((select receives from before), false))) like '%not_authorized%';
insert into results select 'B cannot set an A seller''s goal',
  pg_temp.err(format('select public.set_seller_goal(%L, %L, %L, 1000)', (select org_a from ids), (select seller_user from a), date_trunc('month', current_date)::date)) like '%not_authorized%';
insert into results select 'B cannot rename an A pipeline stage',
  pg_temp.err(format('select public.update_operational_stage(%L, %L, 1, null, true)', (select stage from a), 'Etapa invadida')) like '%not_authorized%';
insert into results select 'B cannot change A''s payout settings',
  pg_temp.err(format('select public.save_payout_settings(%L, %L, %L, 10)', (select org_a from ids), 'closing', 'daily')) like '%not_authorized%';
reset role;

insert into results select 'company A did not change',
  (select receives_leads from public.organization_memberships where id = (select membership from a)) is not distinct from (select receives from before)
  and (select to_jsonb(s) from public.operational_stages s where id = (select stage from a)) = (select stage from before)
  and (select count(*) from public.seller_goals where organization_id = (select org_a from ids)) = (select goals from before);

select set_config('request.jwt.claims', json_build_object('sub', (select admin_a from ids), 'role', 'authenticated')::text, true);
set local role authenticated;
insert into results select 'A''s administrator still changes "receives leads"',
  pg_temp.err(format('select public.set_member_receives_leads(%L, %L)', (select membership from a), not coalesce((select receives from before), false))) = 'ok';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'caller role null contract failed'; end if;
end $$;
rollback;
