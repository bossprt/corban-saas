-- Contract test for 20260925120000_client_profile_v1 (ADR-0033): personal data and registrations only through RPCs that
-- require clientes.edit and sight of the client; the registration password lives only in Vault, is never readable from
-- the table, is shown only to who may edit the client, and every reveal is recorded.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/client-profile-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000a0001'::uuid as agreement,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
       (select id from auth.users where email = 'corretor@corban-teste.local') as broker;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

-- vendedor (clientes.edit, own scope) registers a client and fills the profile.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '71428793860', 'Cliente Ficha Completa', '68999770020', null, 'manual') u;
select public.update_client_profile((select id from made where label = 'client'), date '1980-05-17', 'José da Silva', 'Maria da Silva', '123456', 'sesp', 'ac',
  date '2000-01-10', 'F', 'married', 'Rio Branco', 'ac', '(68) 99988-7766');
insert into results select 'profile saved, text normalized (issuer and UF upper case, WhatsApp +55)',
  (select birth_date = date '1980-05-17' and mother_name = 'Maria da Silva' and rg_issuer = 'SESP' and rg_state = 'AC' and gender = 'F'
          and marital_status = 'married' and birthplace_state = 'AC' and whatsapp = '5568999887766'
   from public.clients where id = (select id from made where label = 'client'));
insert into results select 'WhatsApp enters the contact history',
  exists (select 1 from public.client_contacts where customer_id = (select id from made where label = 'client') and kind = 'whatsapp' and value = '5568999887766');
insert into results select 'birth date in the future is refused',
  pg_temp.err(format($q$select public.update_client_profile(%L, current_date + 1, null, null, null, null, null, null, null, null, null, null, null)$q$, (select id from made where label = 'client'))) = 'invalid_birth_date';
insert into results select 'unknown UF is refused',
  pg_temp.err(format($q$select public.update_client_profile(%L, null, null, null, null, null, 'XX', null, null, null, null, null, null)$q$, (select id from made where label = 'client'))) = 'invalid_state';

-- Two registrations for the same client, one with a password.
insert into made select 'reg1', public.save_client_registration((select id from made where label = 'client'), null, (select agreement from ids), 'Secretaria de Educação',
  'mat-001', 'active', 812.45, date '2026-09-20', 'login.cliente', 'Senha#Secreta123', false, null);
insert into made select 'reg2', public.save_client_registration((select id from made where label = 'client'), null, (select agreement from ids), 'Secretaria de Saúde',
  'MAT-002', 'active', null, null, null, null, false, null);
insert into results select 'a client may have several registrations',
  (select count(*) from public.client_registrations where customer_id = (select id from made where label = 'client')) = 2;
insert into results select 'registration number normalized; margin recorded with date and author',
  (select registration_number = 'MAT-001' and margin_amount = 812.45 and margin_as_of = date '2026-09-20' and margin_updated_by = (select v1 from ids) and has_portal_password
   from public.client_registrations where id = (select id from made where label = 'reg1'));
insert into results select 'the same registration twice is refused',
  pg_temp.err(format($q$select public.save_client_registration(%L, null, %L, null, 'MAT-001', 'active', null, null, null, null, false, null)$q$,
    (select id from made where label = 'client'), (select agreement from ids))) = 'registration_already_exists';
insert into results select 'the Vault reference column is not readable by the API',
  pg_temp.err('select portal_password_secret from public.client_registrations') like 'permission denied%';
insert into results select 'direct write to registrations is refused',
  pg_temp.err(format($q$update public.client_registrations set portal_login = 'x' where id = %L$q$, (select id from made where label = 'reg1'))) is not null;
insert into results select 'the owner of the client sees the password on purpose',
  public.reveal_registration_password((select id from made where label = 'reg1')) = 'Senha#Secreta123';
reset role;

insert into results select 'the password is not stored in clear text anywhere in the table or in Vault storage',
  not exists (select 1 from public.client_registrations r where r::text like '%Senha#Secreta123%')
  and not exists (select 1 from vault.secrets s where s.secret = 'Senha#Secreta123');
insert into results select 'the reveal was recorded (who, which client, which registration)',
  (select count(*) from public.sensitive_access_log where subject_id = (select id from made where label = 'reg1') and actor_user_id = (select v1 from ids)
     and customer_id = (select id from made where label = 'client') and subject_kind = 'registration_password') = 1;

-- Others: a seller who does not see the client, a broker without clientes.edit.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'a seller who does not see the client cannot reveal nor edit',
  pg_temp.err(format($q$select public.reveal_registration_password(%L)$q$, (select id from made where label = 'reg1'))) = 'not_authorized'
  and pg_temp.err(format($q$select public.update_client_profile(%L, null, null, null, null, null, null, null, null, null, null, null, null)$q$, (select id from made where label = 'client'))) = 'not_authorized'
  and not exists (select 1 from public.client_registrations where id = (select id from made where label = 'reg1'));
insert into results select 'a non-admin cannot read the access log',
  not exists (select 1 from public.sensitive_access_log);
reset role;
select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into results select 'without clientes.edit (broker) nobody reveals or saves registrations',
  pg_temp.err(format($q$select public.reveal_registration_password(%L)$q$, (select id from made where label = 'reg1'))) = 'not_authorized'
  and pg_temp.err(format($q$select public.save_client_registration(%L, null, %L, null, 'MAT-009', 'active', null, null, null, null, false, null)$q$,
        (select id from made where label = 'client'), (select agreement from ids))) = 'not_authorized';
reset role;

-- Admin: replace and clear the password, bank accounts, and the log is visible.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.save_client_registration((select id from made where label = 'client'), (select id from made where label = 'reg1'), (select agreement from ids), 'Secretaria de Educação',
  'MAT-001', 'active', 812.45, date '2026-09-20', 'login.cliente', 'NovaSenha456', false, null);
insert into results select 'a new password replaces the old one',
  public.reveal_registration_password((select id from made where label = 'reg1')) = 'NovaSenha456';
insert into results select 'an unchanged margin keeps its author',
  (select margin_updated_by = (select v1 from ids) from public.client_registrations where id = (select id from made where label = 'reg1'));
select public.save_client_registration((select id from made where label = 'client'), (select id from made where label = 'reg1'), (select agreement from ids), 'Secretaria de Educação',
  'MAT-001', 'active', 812.45, date '2026-09-20', 'login.cliente', null, true, null);
insert into results select 'clearing the password removes it',
  (select not has_portal_password from public.client_registrations where id = (select id from made where label = 'reg1'))
  and public.reveal_registration_password((select id from made where label = 'reg1')) is null;
insert into results select 'the administrator reads the access log',
  (select count(*) from public.sensitive_access_log where subject_id = (select id from made where label = 'reg1')) >= 2;
insert into made select 'acc1', public.add_client_bank_account((select id from made where label = 'client'), '001', 'Banco do Brasil', '1234', '567890', '1', 'salary', false);
insert into made select 'acc2', public.add_client_bank_account((select id from made where label = 'client'), '104', 'Caixa', '0001', '123', 'X', 'checking', true);
insert into results select 'first account is primary; a new primary takes the place',
  (select count(*) from public.customer_bank_accounts where customer_id = (select id from made where label = 'client') and is_primary) = 1
  and (select is_primary from public.customer_bank_accounts where id = (select id from made where label = 'acc2'));
insert into results select 'invalid bank code is refused',
  pg_temp.err(format($q$select public.add_client_bank_account(%L, '1', 'X', '1', '1', null, 'checking', false)$q$, (select id from made where label = 'client'))) = 'invalid_bank_code';
select public.set_client_bank_account((select id from made where label = 'acc1'), 'remove');
insert into results select 'an account can be removed',
  not exists (select 1 from public.customer_bank_accounts where id = (select id from made where label = 'acc1'));
reset role;

insert into results select 'anon cannot run the profile RPCs',
  not has_function_privilege('anon', 'public.reveal_registration_password(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.save_client_registration(uuid,uuid,uuid,text,text,text,numeric,date,text,text,boolean,text)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 23 then raise exception 'client profile contract failed'; end if;
end $$;
rollback;
