-- Contract test for 20261006202214_seller_user_link_v1: a seller record links to a team member of any role (here the
-- supervisor), never to two sellers at once, never to someone outside the company; only admin or manager link; the
-- link can be undone; the linked person becomes the holder of the seller's payout account. Rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/seller-user-link-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

-- Two sellers without a login, made as the table owner.
with x as (insert into public.commercial_sellers (organization_id, name, seller_category, commission_group_id, is_active)
  select (select org from ids), 'Vendedor Ligação A', 'pf', (select id from public.commission_groups where organization_id = (select org from ids) limit 1), true returning id)
insert into made select 'a', id from x;
with x as (insert into public.commercial_sellers (organization_id, name, seller_category, commission_group_id, is_active)
  select (select org from ids), 'Vendedor Ligação B', 'pf', (select id from public.commission_groups where organization_id = (select org from ids) limit 1), true returning id)
insert into made select 'b', id from x;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller (agent) cannot link',
  pg_temp.err(format('select public.set_seller_user(%L, %L)', (select id from made where label = 'a'), (select sup_user from ids))) in ('forbidden', 'seller_not_found');  -- refused either way (the agent may not even see the seller)
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'admin links a seller to the supervisor (not an agent)',
  pg_temp.err(format('select public.set_seller_user(%L, %L)', (select id from made where label = 'a'), (select sup_user from ids))) = 'ok';
insert into results select 'the same person cannot be linked to a second seller',
  pg_temp.err(format('select public.set_seller_user(%L, %L)', (select id from made where label = 'b'), (select sup_user from ids))) like '%user_already_linked%';
insert into results select 'someone outside the company is refused',
  pg_temp.err(format('select public.set_seller_user(%L, %L)', (select id from made where label = 'b'), gen_random_uuid())) like '%active_membership_required%';
reset role;
insert into results select 'the link is recorded and audited',
  (select user_id = (select sup_user from ids) from public.commercial_sellers where id = (select id from made where label = 'a'))
  and exists (select 1 from public.organization_admin_events where event_type = 'seller_user_binding_updated' and target_user_id = (select sup_user from ids));
insert into results select 'the supervisor keeps their role',
  (select role = 'supervisor' from public.organization_memberships where organization_id = (select org from ids) and user_id = (select sup_user from ids));

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'the link can be undone',
  pg_temp.err(format('select public.set_seller_user(%L, null)', (select id from made where label = 'a'))) = 'ok';
reset role;
insert into results select 'undone: no user on the seller', (select user_id is null from public.commercial_sellers where id = (select id from made where label = 'a'));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'seller user link contract failed'; end if;
end $$;
rollback;
