-- Contract test for 20260929160000_member_access_with_password_v1: a manager may create or complete a login (and set a
-- member's password) only inside their own company, only for roles they may manage, never for themselves, and never for a
-- login that reaches another company or the platform. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/member-access-password-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as supervisor,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller,
       '00000000-0000-4000-8000-0000000fa001'::uuid as other_org,
       '00000000-0000-4000-8000-0000000fa002'::uuid as outsider,
       '00000000-0000-4000-8000-0000000fa003'::uuid as loose;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.prep(p_email text, p_role text) returns text language sql as $$
  select pg_temp.err(format('select public.prepare_member_access(%L::uuid, %L, %L)', (select org from ids), p_email, p_role))
$$;
grant execute on function pg_temp.prep(text, text) to authenticated;
create function pg_temp.auth_pw(p_user uuid) returns text language sql as $$
  select pg_temp.err(format('select public.authorize_member_password(%L::uuid)',
    (select id from public.organization_memberships where organization_id = (select org from ids) and user_id = p_user)))
$$;
grant execute on function pg_temp.auth_pw(uuid) to authenticated;

-- Fixtures: a login that belongs to another company too, and a login with no company at all (e.g. an old invitation).
insert into public.organizations (id, name, document, plan_type, is_active) values ((select other_org from ids), 'Outra Empresa Teste', 'contrato-' || gen_random_uuid(), 'starter', true);
insert into auth.users (id, email, aud, role) values ((select outsider from ids), 'fora.contrato@corban-teste.local', 'authenticated', 'authenticated'),
                                                     ((select loose from ids), 'solto.contrato@corban-teste.local', 'authenticated', 'authenticated');
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status) values ((select other_org from ids), (select outsider from ids), 'agent', 'active'),
                                                                                           ((select org from ids), (select outsider from ids), 'agent', 'active');
select set_config('corban.membership_rpc', 'off', true);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'new e-mail: prepared, no existing login',
  (select existing_user_id is null and invitation_id is not null from public.prepare_member_access((select org from ids), 'novo.contrato@corban-teste.local', 'agent'));
insert into results select 'second call replaces the pending invitation', pg_temp.prep('novo.contrato@corban-teste.local', 'supervisor') = 'ok';
insert into results select 'login with no company: completed by this company',
  (select existing_user_id = (select loose from ids) from public.prepare_member_access((select org from ids), 'solto.contrato@corban-teste.local', 'agent'));
insert into results select 'member of this company refused', pg_temp.prep('vendedor@corban-teste.local', 'agent') like '%already_member%';
insert into results select 'own e-mail refused', pg_temp.prep('admin@corban-teste.local', 'agent') ~ '(cannot_change_own_membership|already_member)';
insert into results select 'login of another company refused', pg_temp.prep('fora.contrato@corban-teste.local', 'agent') ~ '(email_has_other_access|already_member)';
insert into results select 'invalid e-mail refused', pg_temp.prep('sem-arroba', 'agent') like '%invalid_email%';
insert into results select 'check_login_email: unknown address is free', public.check_login_email((select org from ids), 'ninguem.contrato@corban-teste.local') is null;

insert into results select 'admin may set the password of a seller', pg_temp.auth_pw((select seller from ids)) = 'ok';
insert into results select 'not for the caller', pg_temp.auth_pw((select admin_user from ids)) like '%cannot_change_own_membership%';
insert into results select 'not for a login of two companies', pg_temp.auth_pw((select outsider from ids)) like '%email_has_other_access%';
insert into results select 'recorded after the password is set',
  pg_temp.err(format('select public.record_member_password_set(%L::uuid, true)',
    (select id from public.organization_memberships where organization_id = (select org from ids) and user_id = (select seller from ids)))) = 'ok';
reset role;
insert into results select 'history shows the password change',
  exists (select 1 from public.organization_admin_events where event_type = 'member_password_set' and target_user_id = (select seller from ids)
          and details->>'must_change' = 'true');
insert into results select 'history shows access created with a password',
  exists (select 1 from public.organization_admin_events where event_type = 'invite_created' and target_email = 'novo.contrato@corban-teste.local'
          and details->>'with_password' = 'true');

select pg_temp.act_as((select supervisor from ids));
set local role authenticated;
insert into results select 'supervisor cannot create access', pg_temp.prep('outro.contrato@corban-teste.local', 'agent') like '%not_authorized%';
insert into results select 'supervisor cannot set passwords', pg_temp.auth_pw((select seller from ids)) ~ '(not_authorized|membership_not_found)';
reset role;

select pg_temp.act_as((select seller from ids));
set local role authenticated;
insert into results select 'seller cannot create access', pg_temp.prep('outro2.contrato@corban-teste.local', 'agent') like '%not_authorized%';
reset role;

insert into results select 'anon runs none of them',
  not has_function_privilege('anon', 'public.prepare_member_access(uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.authorize_member_password(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.record_member_password_set(uuid,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.check_login_email(uuid,text)', 'execute');
insert into results select 'helper is private', not has_function_privilege('authenticated', 'private.login_only_in(uuid,uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 19 then raise exception 'member access password contract failed'; end if;
end $$;

rollback;
