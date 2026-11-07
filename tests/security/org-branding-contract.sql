-- Contract test for 20261107200000_org_branding_v1: only an active admin of the company sets its colors and logo;
-- a seller of the same company and the admin of another company cannot; colors must be #rrggbb; a logo must be a file
-- of the company's own folder in 'org-branding'; storage has no UPDATE/DELETE policy for the bucket; anon cannot call.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/org-branding-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-0000000ab001'::uuid as org_a,
       '00000000-0000-4000-8000-0000000ab002'::uuid as org_b,
       '00000000-0000-4000-8000-0000000ab011'::uuid as admin_a,
       '00000000-0000-4000-8000-0000000ab012'::uuid as seller_a,
       '00000000-0000-4000-8000-0000000ab021'::uuid as admin_b;
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
select org_a, 'Marca A', 'marca-a-' || gen_random_uuid(), 'starter', true from ids
union all select org_b, 'Marca B', 'marca-b-' || gen_random_uuid(), 'starter', true from ids;
insert into auth.users (id, email, aud, role)
select admin_a, 'admin.a@marca.local', 'authenticated', 'authenticated' from ids
union all select seller_a, 'vendedor.a@marca.local', 'authenticated', 'authenticated' from ids
union all select admin_b, 'admin.b@marca.local', 'authenticated', 'authenticated' from ids;
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status)
select org_a, admin_a, 'admin', 'active' from ids
union all select org_a, seller_a, 'agent', 'active' from ids
union all select org_b, admin_b, 'admin', 'active' from ids;
select set_config('corban.membership_rpc', 'off', true);

-- A logo file already in the company's folder (stands for the upload).
insert into storage.objects (bucket_id, name, owner_id)
select 'org-branding', org_a::text || '/11111111-1111-4111-8111-111111111111.png', admin_a::text from ids;

insert into results select 'set_org_branding is SECURITY DEFINER with fixed search_path',
  exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'set_org_branding' and p.prosecdef and p.proconfig @> array['search_path=""']);
insert into results select 'anon cannot execute set_org_branding',
  not has_function_privilege('anon', 'public.set_org_branding(uuid, text, text, text, boolean)', 'EXECUTE');
insert into results select 'bucket org-branding is public, 1 MB, raster only',
  exists (select 1 from storage.buckets where id = 'org-branding' and public and file_size_limit = 1048576
          and allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']);
insert into results select 'no UPDATE/DELETE storage policy for org-branding',
  not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
              and policyname like 'org_branding_%' and cmd in ('UPDATE', 'DELETE', 'ALL'));

select pg_temp.act_as((select seller_a from ids));
set local role authenticated;
insert into results select 'a seller of the company cannot change the look',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L)', (select org_a from ids), '#0b5fa8', '#f57c00')) like '%org_branding_forbidden%';
reset role;

select pg_temp.act_as((select admin_b from ids));
set local role authenticated;
insert into results select 'the admin of another company cannot change it',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L)', (select org_a from ids), '#0b5fa8', '#f57c00')) like '%org_branding_forbidden%';
reset role;

select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into results select 'an invalid color is refused',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L)', (select org_a from ids), 'blue', '#f57c00')) like '%org_branding_invalid_color%';
insert into results select 'a logo outside the company folder is refused',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L, %L)', (select org_a from ids), '#0b5fa8', '#f57c00',
    (select org_b from ids)::text || '/11111111-1111-4111-8111-111111111111.png')) like '%org_branding_invalid_logo%';
insert into results select 'a logo that was not uploaded is refused',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L, %L)', (select org_a from ids), '#0b5fa8', '#f57c00',
    (select org_a from ids)::text || '/22222222-2222-4222-8222-222222222222.png')) like '%org_branding_invalid_logo%';
insert into results select 'the admin sets colors (normalized to lowercase) and logo',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L, %L)', (select org_a from ids), '#0B5FA8', '#F57C00',
    (select org_a from ids)::text || '/11111111-1111-4111-8111-111111111111.png')) = 'ok';
reset role;

insert into results select 'company A now has its colors and logo',
  exists (select 1 from public.organizations o, ids where o.id = ids.org_a and o.brand_color = '#0b5fa8' and o.accent_color = '#f57c00'
          and o.logo_path = ids.org_a::text || '/11111111-1111-4111-8111-111111111111.png');
insert into results select 'company B is untouched',
  exists (select 1 from public.organizations o, ids where o.id = ids.org_b and o.brand_color is null and o.logo_path is null);

select pg_temp.act_as((select admin_a from ids));
set local role authenticated;
insert into results select 'the admin removes the logo and keeps colors',
  pg_temp.err(format('select public.set_org_branding(%L, %L, %L, null, true)', (select org_a from ids), '#0b5fa8', '#f57c00')) = 'ok';
reset role;
insert into results select 'logo removed',
  exists (select 1 from public.organizations o, ids where o.id = ids.org_a and o.logo_path is null and o.brand_color = '#0b5fa8');

select check_name, ok from results order by ok, check_name;
do $$ begin if exists (select 1 from results where not ok) then raise exception 'org-branding contract failed'; end if; end $$;
rollback;
