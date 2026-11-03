-- Contract test for 20261103200000_bevicred_credentials_v1: the table, the secret and the functions are closed to tenants;
-- the key is stored only in Vault (encrypted); a company never reaches another company's credential; changing the key
-- replaces the secret and clears the last test. Fictitious credentials. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/bevicred-credentials-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000bb002'::uuid as org_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Bevicred', 'bevicred-' || gen_random_uuid(), 'starter', true from ids;

create temp table cred as
select public.bevicred_save_credential(admin_a, org_a, null, 'Sub', 'SP18-12345', 'chave-ficticia-0001') as id from ids;
grant select on cred to authenticated;

insert into results select 'hint masks the partner code', c.partner_hint = 'SP••••45' from public.bevicred_credentials c, cred where c.id = cred.id;
insert into results select 'key not stored in the table', position('chave-ficticia' in row_to_json(c)::text) = 0
  from public.bevicred_credentials c, cred where c.id = cred.id;
insert into results select 'key encrypted in vault', position('chave-ficticia' in coalesce(s.secret, '')) = 0
  from public.bevicred_credentials c join vault.secrets s on s.id = c.secret_id, cred where c.id = cred.id;
insert into results select 'own company reads the secret',
  public.bevicred_credential_secret(org_a, cred.id) = '{"partner":"SP18-12345","key":"chave-ficticia-0001"}'::jsonb from ids, cred;
insert into results select 'other company gets nothing', public.bevicred_credential_secret(org_b, cred.id) is null from ids, cred;
insert into results select 'other company cannot change it',
  pg_temp.err(format('select public.bevicred_save_credential(null, %L, %L, null, %L, %L)', org_b, cred.id, 'XX99-0000', 'chave-ficticia-9999')) like '%bevicred_credential_not_found%' from ids, cred;
insert into results select 'other company cannot record a test',
  pg_temp.err(format('select public.bevicred_record_test(%L, %L, true, %L)', org_b, cred.id, 'ok')) like '%bevicred_credential_not_found%' from ids, cred;
insert into results select 'same label refused',
  pg_temp.err(format('select public.bevicred_save_credential(null, %L, null, %L, %L, %L)', org_a, 'sub', 'SP18-55555', 'chave-ficticia-0002')) like '%bevicred_label_taken%' from ids;
insert into results select 'short key refused',
  pg_temp.err(format('select public.bevicred_save_credential(null, %L, null, %L, %L, %L)', org_a, 'Outra', 'SP18-55555', 'curta')) like '%bevicred_invalid_credential%' from ids;
insert into results select 'same label allowed in another company',
  pg_temp.err(format('select public.bevicred_save_credential(null, %L, null, %L, %L, %L)', org_b, 'Sub', 'SP18-77777', 'chave-ficticia-0003')) = 'ok' from ids;

select public.bevicred_record_test(org_a, cred.id, true, 'Conectou') from ids, cred;
insert into results select 'test recorded', c.last_test_ok and c.last_test_at is not null from public.bevicred_credentials c, cred where c.id = cred.id;
select public.bevicred_save_credential(admin_a, org_a, cred.id, null, 'SP18-99988', 'chave-ficticia-0004') from ids, cred;
insert into results select 'new key replaces the secret',
  public.bevicred_credential_secret(org_a, cred.id) ->> 'key' = 'chave-ficticia-0004' from ids, cred;
insert into results select 'new key clears the last test', c.last_test_ok is null and c.partner_hint = 'SP••••88' from public.bevicred_credentials c, cred where c.id = cred.id;

-- Tenants (even the company's administrator) reach nothing directly.
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
insert into results values ('admin cannot read the table', pg_temp.err('select count(*) from public.bevicred_credentials') like '%permission denied%');
insert into results select 'admin cannot read the secret',
  pg_temp.err(format('select public.bevicred_credential_secret(%L, %L)', org_a, cred.id)) like '%permission denied%' from ids, cred;
insert into results select 'admin cannot save directly',
  pg_temp.err(format('select public.bevicred_save_credential(null, %L, null, %L, %L, %L)', org_a, 'X', 'SP18-11111', 'chave-ficticia-0005')) like '%permission denied%' from ids;
insert into results select 'admin cannot record a test',
  pg_temp.err(format('select public.bevicred_record_test(%L, %L, true, %L)', org_a, cred.id, 'ok')) like '%permission denied%' from ids, cred;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where ok is not true) then raise exception 'bevicred credentials contract failed'; end if;
  if (select count(*) from results) < 17 then raise exception 'bevicred credentials contract incomplete'; end if;
end $$;

rollback;
