-- Contract test for 20261006_seller_contracts_v1: the external broker sees every contract where they are the seller,
-- also the ones the company typed for them, with their payable share; never another seller's contract; a member
-- without a seller record gets an empty list; another company is refused. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/seller-contracts-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0802'::uuid as broker_seller,
       '00000000-0000-4000-8000-0000000c0801'::uuid as other_seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'corretor@corban-teste.local') as broker,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table seen (b jsonb);
grant insert, select on seen to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

-- The company (admin) types one contract for the broker and one for another seller.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Portal', '68999770019', null, 'manual') u;
insert into made select 'mine', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select broker_seller from ids), 10000, 9000, 250, 120, 'ADE-PORTAL-MINE', 'submitted') d;
insert into made select 'other', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select other_seller from ids), 8000, 7000, 200, 120, 'ADE-PORTAL-OTHER', 'submitted') d;
reset role;

select pg_temp.act_as((select broker from ids));
set local role authenticated;
insert into seen select public.seller_contracts((select org from ids));
insert into results select 'another company is refused',
  pg_temp.err(format('select public.seller_contracts(%L)', gen_random_uuid())) like '%not_authorized%';
reset role;

insert into results select 'the contract the company typed for the broker is listed, marked as typed by the company',
  exists (select 1 from seen, jsonb_array_elements(b) c where (c->>'id')::uuid = (select id from made where label = 'mine') and (c->>'by_me')::boolean = false);
insert into results select 'another seller''s contract is not listed',
  not exists (select 1 from seen, jsonb_array_elements(b) c where (c->>'id')::uuid = (select id from made where label = 'other'));
insert into results select 'every listed contract is the broker''s',
  not exists (select 1 from seen, jsonb_array_elements(b) c join public.proposals_v2 p on p.id = (c->>'id')::uuid where p.seller_id <> (select broker_seller from ids));
insert into results select 'the share is the payable amount of the contract',
  (select (c->>'payable')::numeric from seen, jsonb_array_elements(b) c where (c->>'id')::uuid = (select id from made where label = 'mine'))
  = (select coalesce(sum(payable), 0) from private.contract_payable((select id from made where label = 'mine')));

select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'a member without a seller record gets an empty list', public.seller_contracts((select org from ids)) = '[]'::jsonb;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'seller contracts contract failed'; end if;
end $$;
rollback;
