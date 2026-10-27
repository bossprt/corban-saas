-- Contract test for 20261027120000_internal_seller_v1: an internal seller (a channel of the company itself, such as paid
-- traffic) is saved without CPF/CNPJ, mobile or e-mail; a regular seller still needs all three. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/internal-seller-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0601'::uuid as grp,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
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
create function pg_temp.save(p_data jsonb) returns text language sql as $$
  select format('select public.save_seller(%L, null, %L)', (select org from ids), p_data);
$$;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;

insert into made select 'internal', public.save_seller((select org from ids), null, jsonb_build_object(
  'name', 'TRAFEGO PAGO - TESTE', 'tax_id', '', 'category', 'pj', 'group_id', (select grp from ids), 'internal', true, 'profile', '{}'::jsonb));
insert into made select 'internal 2', public.save_seller((select org from ids), null, jsonb_build_object(
  'name', 'BALCAO - TESTE', 'category', 'pj', 'group_id', (select grp from ids), 'internal', true));
insert into results select 'an internal seller is saved without CPF/CNPJ, mobile or e-mail',
  (select is_internal and tax_id is null from public.commercial_sellers where id = (select id from made where label = 'internal'));
insert into results select 'two internal sellers can coexist (no document to repeat)',
  (select count(*) = 2 from public.commercial_sellers where id in (select id from made));
insert into results select 'an internal seller cannot carry a CPF/CNPJ',
  pg_temp.err(pg_temp.save(jsonb_build_object('name', 'X', 'tax_id', '111.444.777-35', 'category', 'pj', 'group_id', (select grp from ids), 'internal', true))) = 'seller_internal_no_tax_id';
insert into results select 'an internal seller with a bad e-mail is refused',
  pg_temp.err(pg_temp.save(jsonb_build_object('name', 'X', 'category', 'pj', 'group_id', (select grp from ids), 'internal', true, 'profile', jsonb_build_object('email', 'nope')))) = 'seller_email_required';
insert into results select 'a regular seller still needs a CPF/CNPJ',
  pg_temp.err(pg_temp.save(jsonb_build_object('name', 'X', 'category', 'pj', 'group_id', (select grp from ids), 'profile', jsonb_build_object('mobile', '68999770000', 'email', 'x@example.com')))) = 'seller_tax_id_invalid';
insert into results select 'a regular seller still needs a mobile',
  pg_temp.err(pg_temp.save(jsonb_build_object('name', 'X', 'tax_id', '111.444.777-35', 'category', 'pf', 'group_id', (select grp from ids), 'profile', jsonb_build_object('email', 'x@example.com')))) = 'seller_mobile_required';
-- Turning a seller into a regular one requires its document again.
insert into results select 'an internal seller turned regular needs a CPF/CNPJ',
  pg_temp.err(format('select public.save_seller(%L, %L, %L)', (select org from ids), (select id from made where label = 'internal'),
    jsonb_build_object('name', 'TRAFEGO PAGO - TESTE', 'category', 'pj', 'group_id', (select grp from ids), 'internal', false,
      'profile', jsonb_build_object('mobile', '68999770000', 'email', 'x@example.com')))) = 'seller_tax_id_invalid';
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'internal seller contract failed'; end if;
end $$;
rollback;
