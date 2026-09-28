-- Contract test for 20260928200000_bank_document_checklist_v1: the documents each bank asks for, saved per route as a new
-- published version (the previous one superseded, never edited), only by supervision roles, only with active types.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/bank-checklist-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0101'::uuid as route,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from public.document_types where code = 'rg') as rg,
       (select id from public.document_types where code = 'comprovante_residencia') as res,
       (select id from public.document_types where code = 'contracheque') as cc;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.published() returns uuid language sql as $$
  select id from public.document_checklist_templates where route_id = (select route from ids) and status = 'published'
$$;
grant execute on function pg_temp.published() to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'admin saves a checklist for the route',
  public.save_route_checklist((select org from ids), array[(select route from ids)],
    jsonb_build_array(jsonb_build_object('document_type_id', (select rg from ids), 'required', true),
                      jsonb_build_object('document_type_id', (select res from ids), 'required', false, 'label', 'Conta de luz ou água'))) = 1;
insert into results select 'items keep order, label and required flag',
  (select array_agg(label || ':' || is_required order by sort_order) from public.document_checklist_items where template_id = pg_temp.published())
  = array['RG (documento de identidade):true', 'Conta de luz ou água:false'];
create temp table first_version as select pg_temp.published() as id;
grant select on first_version to authenticated;
select public.save_route_checklist((select org from ids), array[(select route from ids)],
  jsonb_build_array(jsonb_build_object('document_type_id', (select cc from ids))));
insert into results select 'saving again publishes a new version and supersedes the old one',
  (select status = 'superseded' from public.document_checklist_templates where id = (select id from first_version))
  and (select count(*) = 1 from public.document_checklist_templates where route_id = (select route from ids) and status = 'published')
  and (select version from public.document_checklist_templates where id = pg_temp.published())
      = (select version + 1 from public.document_checklist_templates where id = (select id from first_version));
insert into results select 'the old version keeps its items',
  (select count(*) = 2 from public.document_checklist_items where template_id = (select id from first_version));
insert into results select 'the same type twice is refused',
  pg_temp.err(format('select public.save_route_checklist(%L, array[%L]::uuid[], %L::jsonb)', (select org from ids), (select route from ids),
    jsonb_build_array(jsonb_build_object('document_type_id', (select rg from ids)), jsonb_build_object('document_type_id', (select rg from ids))))) = 'duplicate_checklist_items';
insert into results select 'an unknown type is refused',
  pg_temp.err(format('select public.save_route_checklist(%L, array[%L]::uuid[], %L::jsonb)', (select org from ids), (select route from ids),
    jsonb_build_array(jsonb_build_object('document_type_id', gen_random_uuid())))) = 'invalid_checklist_items';
insert into results select 'an empty list is refused',
  pg_temp.err(format('select public.save_route_checklist(%L, array[%L]::uuid[], %L::jsonb)', (select org from ids), (select route from ids), '[]')) = 'invalid_checklist_items';
insert into results select 'a route of another company is refused',
  pg_temp.err(format('select public.save_route_checklist(%L, array[%L]::uuid[], %L::jsonb)', (select org from ids), gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('document_type_id', (select rg from ids))))) = 'route_not_found';
insert into results select 'a published checklist cannot be edited directly',
  pg_temp.err(format('update public.document_checklist_templates set name = %L where id = %L', 'x', pg_temp.published())) <> 'ok';
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot save a checklist',
  pg_temp.err(format('select public.save_route_checklist(%L, array[%L]::uuid[], %L::jsonb)', (select org from ids), (select route from ids),
    jsonb_build_array(jsonb_build_object('document_type_id', (select rg from ids))))) = 'not_authorized';
reset role;
insert into results select 'anon cannot run it', not has_function_privilege('anon', 'public.save_route_checklist(uuid,uuid[],jsonb)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 11 then raise exception 'bank checklist contract failed'; end if;
end $$;

rollback;
