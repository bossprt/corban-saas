-- Contract test for 20261105120000_seller_signup_links_v1: registration link per seller group. Anonymous callers reach
-- only the link info and the submit, by token; the queue is read and decided only by admin/manager of the company; an
-- approval runs save_seller and erases the request's data. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/seller-signup-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000bb004'::uuid as org_b,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_a,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as super_a,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as agent_a,
       (select id from public.commission_groups where organization_id = '00000000-0000-4000-8000-00000000c0b1' and is_active limit 1) as group_a,
       null::uuid as group_b, null::text as token_a, null::text as token_b, null::uuid as req_a, null::uuid as req_b, null::uuid as seller_a;
grant select, update on ids to authenticated, anon;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated, anon;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated, anon;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- A valid request body (fictitious CPF with valid check digits).
create function pg_temp.body(p_tax text) returns jsonb language sql as $$
  select jsonb_build_object('name', 'Pessoa Teste Link', 'tax_id', p_tax, 'category', 'pf', 'group_id', gen_random_uuid(), 'internal', true,
    'profile', jsonb_build_object('mobile', '68999990000', 'email', 'link@teste.local', 'mother_name', 'Mae Teste'),
    'accounts', jsonb_build_array(jsonb_build_object('transfer_method', 'pix', 'pix_key_type', 'email', 'pix_key', 'link@teste.local', 'primary', true)),
    'contacts', '[]'::jsonb)
$$;
grant execute on function pg_temp.body(text) to authenticated, anon;

insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B link cadastro', 'signup-' || gen_random_uuid(), 'starter', true from ids;
insert into public.commission_groups (organization_id, name)
select org_b, 'Corretor B' from ids;
update ids set group_b = (select id from public.commission_groups where organization_id = org_b limit 1);
insert into results select 'fixtures present', admin_a is not null and super_a is not null and agent_a is not null and group_a is not null and group_b is not null from ids;

-- Links: admin creates for own group only; supervisor and agent cannot.
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
update ids set token_a = public.seller_signup_link_new(org_a, group_a);
insert into results select 'admin creates link', token_a ~ '^[A-Za-z0-9_-]{24}$' from ids;
insert into results select 'admin cannot create link for another company',
  pg_temp.err(format('select public.seller_signup_link_new(%L, %L)', org_b, group_b)) like '%not_authorized%' from ids;
insert into results select 'admin cannot use group of another company',
  pg_temp.err(format('select public.seller_signup_link_new(%L, %L)', org_a, group_b)) like '%seller_group_invalid%' from ids;
insert into results values ('admin reads own links only', (select count(*) from public.seller_signup_links) = 1);
insert into results values ('tables not writable directly', pg_temp.err('update public.seller_signup_links set is_active = false') like '%permission denied%');
select pg_temp.act_as(super_a) from ids;
insert into results select 'supervisor cannot create link', pg_temp.err(format('select public.seller_signup_link_new(%L, %L)', org_a, group_a)) like '%not_authorized%' from ids;
insert into results values ('supervisor sees no links', (select count(*) from public.seller_signup_links) = 0);
select pg_temp.act_as(agent_a) from ids;
insert into results select 'agent cannot create link', pg_temp.err(format('select public.seller_signup_link_new(%L, %L)', org_a, group_a)) like '%not_authorized%' from ids;
reset role;
insert into public.seller_signup_links (organization_id, commission_group_id, token) select org_b, group_b, 'tokenEmpresaB_0123456789ab' from ids;
update ids set token_b = 'tokenEmpresaB_0123456789ab';

-- Anonymous: info and submit by token; nothing else.
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
insert into results select 'anon reads link info', (select group_name from public.seller_signup_link_info(token_a)) is not null from ids;
insert into results values ('anon unknown token shows nothing', (select count(*) from public.seller_signup_link_info('naoexiste_0123456789abcd')) = 0);
insert into results values ('anon cannot read tables', pg_temp.err('select count(*) from public.seller_signup_requests') like '%permission denied%');
insert into results select 'anon cannot create link', pg_temp.err(format('select public.seller_signup_link_new(%L, %L)', org_a, group_a)) like '%permission denied%' from ids;
insert into results select 'anon cannot approve', pg_temp.err(format('select public.seller_signup_approve(%L, %L)', gen_random_uuid(), '{}')) like '%permission denied%' from ids;
insert into results select 'anon submits', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('52998224725'))) = 'ok' from ids;
insert into results select 'same document replaces the waiting request', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('529.982.247-25'))) = 'ok' from ids;
insert into results select 'invalid CPF refused', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('52998224700'))) like '%seller_tax_id_invalid%' from ids;
insert into results select 'missing e-mail refused', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('52998224725') #- '{profile,email}')) like '%seller_email_required%' from ids;
insert into results select 'too many accounts refused', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a,
  jsonb_set(pg_temp.body('52998224725'), '{accounts}', (select jsonb_agg('{}'::jsonb) from generate_series(1, 6))))) like '%signup_invalid%' from ids;
insert into results select 'company B request', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_b, pg_temp.body('11144477735'))) = 'ok' from ids;
reset role;
select set_config('request.jwt.claims', '', true);
insert into results select 'one waiting request per document', (select count(*) from public.seller_signup_requests where organization_id = org_a and tax_id = '52998224725' and status = 'pending') = 1 from ids;
insert into results select 'group and admin fields not kept',
  (select r.commission_group_id = i.group_a and not (r.payload ? 'group_id') and not (r.payload ? 'internal') from public.seller_signup_requests r where r.organization_id = i.org_a) from ids i;
update ids set req_a = (select id from public.seller_signup_requests where organization_id = org_a and status = 'pending'),
  req_b = (select id from public.seller_signup_requests where organization_id = org_b);

-- Link off: info and submit stop.
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
select public.seller_signup_link_set_active((select id from public.seller_signup_links where token = token_a), false) from ids;
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
insert into results select 'link off shows nothing', (select count(*) from public.seller_signup_link_info(token_a)) = 0 from ids;
insert into results select 'link off refuses submit', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('11144477735'))) like '%signup_link_closed%' from ids;
reset role;

-- Queue: admin of the company reads and approves; the request closes and its data is erased.
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
insert into results values ('admin reads own requests only', (select count(*) from public.seller_signup_requests) = 1);
insert into results select 'admin cannot reject another company request',
  pg_temp.err(format('select public.seller_signup_reject(%L)', req_b)) like '%not_authorized%' from ids;
update ids set seller_a = public.seller_signup_approve(req_a, jsonb_set(pg_temp.body('52998224725'), '{group_id}', to_jsonb(group_a)) - 'internal');
insert into results select 'approval creates the seller', (select s.commission_group_id = i.group_a from public.commercial_sellers s where s.id = i.seller_a) from ids i;
insert into results select 'approval twice refused', pg_temp.err(format('select public.seller_signup_approve(%L, %L)', req_a, pg_temp.body('52998224725'))) like '%signup_already_decided%' from ids;
select pg_temp.act_as(super_a) from ids;
insert into results values ('supervisor sees no requests', (select count(*) from public.seller_signup_requests) = 0);
reset role;
insert into results select 'approved request keeps no data',
  (select status = 'approved' and payload is null and seller_id = i.seller_a from public.seller_signup_requests where id = i.req_a) from ids i;

-- Rejection erases the data too; flooding is limited.
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
select public.seller_signup_link_set_active((select id from public.seller_signup_links where token = token_a), true) from ids;
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select public.seller_signup_submit(token_a, pg_temp.body('11144477735')) from ids;
reset role;
set local role authenticated;
select pg_temp.act_as(admin_a) from ids;
select public.seller_signup_reject((select id from public.seller_signup_requests where status = 'pending'));
reset role;
insert into results select 'rejected request keeps no data',
  (select payload is null and decided_at is not null from public.seller_signup_requests where organization_id = org_a and status = 'rejected') from ids;
insert into public.seller_signup_requests (organization_id, link_id, commission_group_id, name, tax_id, payload)
select org_a, l.id, group_a, 'Lote', lpad(g::text, 11, '0'), '{}'::jsonb
from ids, public.seller_signup_links l, generate_series(1, 30) g where l.token = ids.token_a;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
insert into results select 'more than 30 per hour refused', pg_temp.err(format('select public.seller_signup_submit(%L, %L)', token_a, pg_temp.body('39053344705'))) like '%signup_rate_limited%' from ids;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where ok is not true) then raise exception 'seller signup contract failed'; end if;
  if (select count(*) from results) < 30 then raise exception 'seller signup contract incomplete'; end if;
end $$;

rollback;
