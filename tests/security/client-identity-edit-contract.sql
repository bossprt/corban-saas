-- Contract test for 20260925053116_client_identity_edit_v1: name, phone and e-mail of an existing client change only through
-- update_client_identity (clientes.edit and sight of the client); the previous phone stays in the history; the CPF never
-- changes; an existing bank account is edited only by who may edit the client.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/client-identity-edit-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
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

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '86288366757', 'Nome Antigo', '68999770030', 'antigo@exemplo.com', 'manual') u;
select public.update_client_identity((select id from made where label = 'client'), 'Nome Corrigido', '(68) 98888-7777', 'novo@exemplo.com');
insert into results select 'name, phone and e-mail updated; CPF unchanged',
  (select full_name = 'Nome Corrigido' and phone = '5568988887777' and email = 'novo@exemplo.com' and cpf = '86288366757'
   from public.clients where id = (select id from made where label = 'client'));
insert into results select 'the previous phone stays in the history, the new one is the main one',
  (select count(*) from public.client_contacts where customer_id = (select id from made where label = 'client') and kind = 'phone') = 2
  and (select value from public.client_contacts where customer_id = (select id from made where label = 'client') and kind = 'phone' and is_primary) = '5568988887777';
insert into results select 'a name too short is refused',
  pg_temp.err(format($q$select public.update_client_identity(%L, 'AB', null, null)$q$, (select id from made where label = 'client'))) = 'full_name_required';
insert into results select 'an invalid phone is refused',
  pg_temp.err(format($q$select public.update_client_identity(%L, 'Nome Valido', '123', null)$q$, (select id from made where label = 'client'))) = 'invalid_phone';
insert into made select 'acc', public.add_client_bank_account((select id from made where label = 'client'), '001', 'Banco do Brasil', '1234', '1111', null, 'checking', false);
select public.update_client_bank_account((select id from made where label = 'acc'), '237', 'Bradesco', '0001', '2222', '5', 'savings');
insert into results select 'an existing account is edited',
  (select bank_code = '237' and bank_name = 'Bradesco' and account_number = '2222' and account_digit = '5' and account_type = 'savings'
   from public.customer_bank_accounts where id = (select id from made where label = 'acc'));
reset role;

select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'a seller who does not see the client cannot edit identity nor accounts',
  pg_temp.err(format($q$select public.update_client_identity(%L, 'Invasor', null, null)$q$, (select id from made where label = 'client'))) = 'not_authorized'
  and pg_temp.err(format($q$select public.update_client_bank_account(%L, '001', 'X Banco', '1', '1', null, 'checking')$q$, (select id from made where label = 'acc'))) = 'not_authorized';
reset role;
select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into results select 'without clientes.edit (broker) nobody edits identity',
  pg_temp.err(format($q$select public.update_client_identity(%L, 'Invasor', null, null)$q$, (select id from made where label = 'client'))) = 'not_authorized';
reset role;
insert into results select 'anon cannot run the identity RPCs',
  not has_function_privilege('anon', 'public.update_client_identity(uuid,text,text,text)', 'execute')
  and not has_function_privilege('anon', 'public.update_client_bank_account(uuid,text,text,text,text,text,text)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 8 then raise exception 'client identity contract failed'; end if;
end $$;
rollback;
