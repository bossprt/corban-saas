-- Contract test for 20260925090000_client_identity_v1 (local test company and users, see data-scope-contract.sql).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/client-identity-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid, created boolean, visible boolean);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into results select 'CPF check digits are validated', private.is_valid_cpf('52998224725') and not private.is_valid_cpf('52998224724') and not private.is_valid_cpf('11111111111');
insert into results select 'phones normalize to 55 + DDD + number', private.normalize_phone('(68) 99900-0101') = '5568999000101' and private.normalize_phone('+55 68 99900-0101') = '5568999000101' and private.normalize_phone('123') is null;

-- Vendedor Um registers a new client.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'first', u.client_id, u.created, u.visible from public.upsert_client((select org from ids), '52998224725', 'Cliente Identidade', '(68) 99900-0101', 'um@example.com', 'manual') u;
insert into results select 'new CPF creates a client', created and visible from made where label = 'first';
reset role;

-- Vendedor Dois registers the same CPF with a new phone.
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into made select 'second', u.client_id, u.created, u.visible from public.upsert_client((select org from ids), '52998224725', 'Outro Nome', '68 98888-0202', null, 'manual') u;
insert into results select 'same CPF is recognized, not duplicated', (select id from made where label = 'second') = (select id from made where label = 'first') and not (select created from made where label = 'second');
insert into results select 'other seller learns it exists but cannot see it', not (select visible from made where label = 'second');
insert into results select 'other seller still cannot read the client', not exists (select 1 from public.clients where id = (select id from made where label = 'first'));
do $$ begin
  begin
    perform public.upsert_client((select org from ids), '52998224724', 'CPF Errado', null, null, 'manual');
    insert into results values ('invalid CPF is refused', false);
  exception when others then
    insert into results values ('invalid CPF is refused', sqlerrm = 'invalid_cpf');
  end;
  begin
    perform public.upsert_client(gen_random_uuid(), '52998224725', 'Outra Empresa', null, null, 'manual');
    insert into results values ('another company is refused', false);
  exception when others then
    insert into results values ('another company is refused', sqlerrm = 'not_authorized');
  end;
end $$;
reset role;

-- As the owner of the check (no RLS): one client, both phones in history, the new one primary, name kept.
insert into results select 'exactly one client for the CPF', count(*) = 1 from public.clients where organization_id = (select org from ids) and cpf = '52998224725' and deleted_at is null;
insert into results select 'original name is kept', full_name = 'Cliente Identidade' from public.clients where id = (select id from made where label = 'first');
insert into results select 'both phones are in the history', count(*) = 2 from public.client_contacts where customer_id = (select id from made where label = 'first') and kind = 'phone';
insert into results select 'newest phone is the primary', value = '5568988880202' from public.client_contacts where customer_id = (select id from made where label = 'first') and kind = 'phone' and is_primary;
insert into results select 'client main phone follows the newest', phone = '5568988880202' from public.clients where id = (select id from made where label = 'first');
insert into results select 'recognition is on the timeline', exists (select 1 from public.customer_timeline_events where customer_id = (select id from made where label = 'first') and event_type = 'customer.recognized');
insert into results select 'owner stays with the first seller', owner_user_id = (select v1 from ids) from public.clients where id = (select id from made where label = 'first');

-- The first seller sees the contact history of his client; the second does not.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'owner sees contact history', count(*) = 2 from public.client_contacts where customer_id = (select id from made where label = 'first') and kind = 'phone';
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'other seller does not see contact history', not exists (select 1 from public.client_contacts where customer_id = (select id from made where label = 'first'));
do $$ begin
  begin
    insert into public.client_contacts (organization_id, customer_id, kind, value, source) values ((select org from ids), (select id from made where label = 'first'), 'phone', '5568911112222', 'hack');
    insert into results values ('contacts cannot be written directly', false);
  exception when others then
    insert into results values ('contacts cannot be written directly', true);
  end;
end $$;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'client identity contract failed'; end if;
end $$;

rollback;
