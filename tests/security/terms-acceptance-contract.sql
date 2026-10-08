-- Contract test for 20261008_terms_acceptance_v1: with no version published nothing is pending; once one is, the
-- company is pending until its administrator accepts; a seller or another company's administrator cannot accept; the
-- acceptance keeps who, when, IP, browser and the text's SHA-256; it cannot be changed or deleted; an older version
-- cannot be accepted; a new version makes the company pending again. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/terms-acceptance-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000b0b01'::uuid as org_b,
       '00000000-0000-4000-8000-0000000b0b02'::uuid as admin_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_a;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table v (label text, id uuid);
grant select on v to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Termos', 'termos-' || gen_random_uuid(), 'starter', true from ids;
insert into auth.users (id, email, aud, role) select admin_b, 'admin.b@termos.local', 'authenticated', 'authenticated' from ids;
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status) select org_b, admin_b, 'admin', 'active' from ids;
select set_config('corban.membership_rpc', 'off', true);

-- Start from no version at all (the test owns this transaction).
alter table public.terms_versions disable trigger terms_versions_immutable;
alter table public.organization_terms_acceptances disable trigger organization_terms_acceptances_immutable;
delete from public.organization_terms_acceptances;
delete from public.terms_versions;
alter table public.terms_versions enable trigger terms_versions_immutable;
alter table public.organization_terms_acceptances enable trigger organization_terms_acceptances_immutable;

select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into results select 'no version published: nothing pending', public.terms_pending((select org_a from ids)) = false;
insert into results select 'nobody can publish a version from the app',
  pg_temp.err($q$insert into public.terms_versions (version, title, body, body_sha256) values ('x', 'Termos', repeat('a', 30), repeat('0', 64))$q$) like '%permission denied%';
reset role;

insert into public.terms_versions (version, title, body, body_sha256, published_at)
values ('2026-10-v1', 'Termos de Uso', repeat('Texto dos termos. ', 5), encode(sha256(convert_to(repeat('Texto dos termos. ', 5), 'UTF8')), 'hex'), now() - interval '1 minute');
insert into v select 'v1', id from public.terms_versions where version = '2026-10-v1';

select pg_temp.act_as((select seller_a from ids));
set local role authenticated;
insert into results select 'published: company A is pending', public.terms_pending((select org_a from ids)) = true;
insert into results select 'the seller sees the terms but cannot accept',
  (public.terms_status((select org_a from ids))->>'can_accept')::boolean = false
  and pg_temp.err(format('select public.accept_terms(%L, %L, null, null)', (select org_a from ids), (select id from v where label = 'v1'))) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_b from ids));
set local role authenticated;
insert into results select 'another company''s administrator cannot accept for A',
  pg_temp.err(format('select public.accept_terms(%L, %L, null, null)', (select org_a from ids), (select id from v where label = 'v1'))) like '%not_authorized%';
insert into results select 'another company''s administrator cannot read A''s status',
  pg_temp.err(format('select public.terms_status(%L)', (select org_a from ids))) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into results select 'A''s administrator accepts (twice is the same acceptance)',
  pg_temp.err(format('select public.accept_terms(%L, %L, %L, %L)', (select org_a from ids), (select id from v where label = 'v1'), '200.1.2.3', 'Teste/1.0')) = 'ok'
  and pg_temp.err(format('select public.accept_terms(%L, %L, null, null)', (select org_a from ids), (select id from v where label = 'v1'))) = 'ok';
insert into results select 'after accepting, nothing pending', public.terms_pending((select org_a from ids)) = false;
reset role;

insert into results select 'the acceptance keeps who, IP, browser and the text hash',
  (select count(*) = 1 and bool_and(accepted_by = (select admin_a from ids) and ip = '200.1.2.3' and user_agent = 'Teste/1.0'
     and body_sha256 = (select body_sha256 from public.terms_versions where id = (select id from v where label = 'v1')))
   from public.organization_terms_acceptances where organization_id = (select org_a from ids));
insert into results select 'company B is still pending (acceptance is per company)',
  not exists (select 1 from public.organization_terms_acceptances where organization_id = (select org_b from ids));
insert into results select 'an acceptance cannot be changed',
  pg_temp.err(format('update public.organization_terms_acceptances set ip = %L where organization_id = %L', 'x', (select org_a from ids))) like '%terms_records_are_immutable%';
insert into results select 'an acceptance cannot be deleted',
  pg_temp.err(format('delete from public.organization_terms_acceptances where organization_id = %L', (select org_a from ids))) like '%terms_records_are_immutable%';
insert into results select 'a published text cannot be changed',
  pg_temp.err(format('update public.terms_versions set body = %L where id = %L', repeat('outro texto ', 5), (select id from v where label = 'v1'))) like '%terms_records_are_immutable%';

-- A new version: A is pending again and the old one can no longer be accepted.
insert into public.terms_versions (version, title, body, body_sha256)
values ('2026-11-v2', 'Termos de Uso', repeat('Texto novo dos termos. ', 5), encode(sha256(convert_to(repeat('Texto novo dos termos. ', 5), 'UTF8')), 'hex'));
select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into results select 'a new version makes A pending again', public.terms_pending((select org_a from ids)) = true;
insert into results select 'the old version can no longer be accepted',
  pg_temp.err(format('select public.accept_terms(%L, %L, null, null)', (select org_a from ids), (select id from v where label = 'v1'))) like '%terms_version_not_current%';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'terms acceptance contract failed'; end if;
end $$;
rollback;
