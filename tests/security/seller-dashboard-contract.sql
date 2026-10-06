-- Contract test for 20261006200125_seller_dashboard_v1: a seller sees only their own numbers (their contracts, their payable
-- share, their account); a member without a seller record gets nothing; another company is refused.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/seller-dashboard-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
       (select s.id from public.commercial_sellers s join auth.users u on u.id = s.user_id where u.email = 'vendedor@corban-teste.local') as seller1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table board (who text, b jsonb);
grant insert, select on board to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into board select 'v1', public.seller_dashboard((select org from ids));
insert into results select 'another company is refused',
  pg_temp.err(format('select public.seller_dashboard(%L)', gen_random_uuid())) like '%not_authorized%';
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into board select 'v2', public.seller_dashboard((select org from ids));
reset role;

insert into results select 'a member without a seller record gets nothing', (select b = '{"seller": false}'::jsonb from board where who = 'v2');
insert into results select 'the seller sees their own name and blocks',
  (select (b->>'seller')::boolean and b ?& array['goal', 'expected', 'released', 'received_month', 'pending', 'recent'] from board where who = 'v1');
insert into results select 'recent contracts are all the seller''s own',
  not exists (select 1 from board, jsonb_array_elements(b->'recent') r join public.proposals_v2 p on p.id = (r->>'id')::uuid
              where who = 'v1' and p.seller_id is distinct from (select seller1 from ids));
insert into results select 'expected = payable of their contracts not released yet',
  (select (b->>'expected')::numeric from board where who = 'v1')
  = (select coalesce(sum((select coalesce(sum(x.payable), 0) from private.contract_payable(p.id) x)), 0)
     from public.proposals_v2 p cross join lateral private.contract_credit_state(p.id) st
     where p.seller_id = (select seller1 from ids) and p.status not in ('cancelled', 'rejected') and st.paid_on is null and st.waiting is not null and st.waiting <> 'no_payout');
insert into results select 'no company figure in the answer',
  (select not (b ?| array['margin', 'production', 'received', 'banks']) from board where who = 'v1');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'seller dashboard contract failed'; end if;
end $$;
rollback;
