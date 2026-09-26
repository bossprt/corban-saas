-- Contract test for 20260926040000_import_row_origin_v1 (ADR-0038): one imported file can carry the origin of each
-- row (own production or an active partner of the company); rows without it keep the origin chosen on screen; an
-- unknown, inactive or other-company partner is refused and nothing is written.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/import-row-origin-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0401'::uuid as ctype,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- One import row of table p_table (single term 84x, 5% à vista on the gross), with optional origin keys.
create function pg_temp.row_of(p_table text, p_origin jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('bank_name', 'Banco Origem', 'agreement_name', 'Convênio Origem', 'table_name', p_table,
    'contract_type_id', (select ctype from ids), 'contract_type_name', 'Novo (teste)', 'term', 84, 'rate', '1.8',
    'components', jsonb_build_array(jsonb_build_object('component_type_id', (select id from public.commission_component_types where tech_key = 'upfront'),
      'value_kind', 'percentage', 'received_value', '5', 'calculation_base', 'BRUTO', 'source', 'import')),
    'group_values', '[]'::jsonb) || p_origin
$$;
grant execute on function pg_temp.row_of(text, jsonb) to authenticated;
create function pg_temp.origin_of(p_table text) returns text language sql as $$
  select r.production_origin || ':' || coalesce(p.name, '-')
  from public.product_tables t join public.organization_product_routes r on r.id = t.route_id
  left join public.organization_providers p on p.id = r.org_provider_id
  where t.name = p_table
$$;
grant execute on function pg_temp.origin_of(text) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into public.organization_providers (organization_id, name, provider_type) values ((select org from ids), 'Promotora Origem A', 'promotora');
insert into public.organization_providers (organization_id, name, provider_type, is_active) values ((select org from ids), 'Promotora Inativa', 'promotora', false);
insert into made select 'prov', id from public.organization_providers where name = 'Promotora Origem A';
insert into made select 'inactive', id from public.organization_providers where name = 'Promotora Inativa';

-- Screen says "own"; one row says its partner, one says own, one says nothing.
select public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
  pg_temp.row_of('T Parceira', jsonb_build_object('production_origin', 'third_party', 'provider_id', (select id from made where label = 'prov'))),
  pg_temp.row_of('T Propria', jsonb_build_object('production_origin', 'own', 'provider_id', null)),
  pg_temp.row_of('T Sem coluna')));
insert into results select 'a row with a partner goes to that partner', pg_temp.origin_of('T Parceira') = 'third_party:Promotora Origem A';
insert into results select 'a row marked own is own production', pg_temp.origin_of('T Propria') = 'own:-';
insert into results select 'a row without origin keeps the screen choice', pg_temp.origin_of('T Sem coluna') = 'own:-';

-- Screen says a partner; a row marked own still goes to own production.
select public.import_smart_commercial_rows((select org from ids), 'third_party', (select id from made where label = 'prov'), null, jsonb_build_array(
  pg_temp.row_of('T Mista', jsonb_build_object('production_origin', 'own', 'provider_id', null)),
  pg_temp.row_of('T Tela')));
insert into results select 'the row origin wins over the screen', pg_temp.origin_of('T Mista') = 'own:-';
insert into results select 'the screen origin applies to rows without one', pg_temp.origin_of('T Tela') = 'third_party:Promotora Origem A';

do $$
declare v_before bigint := (select count(*) from public.product_tables);
begin
  begin
    perform public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
      pg_temp.row_of('T Boa'), pg_temp.row_of('T Ruim', jsonb_build_object('production_origin', 'third_party', 'provider_id', gen_random_uuid()))));
    insert into results values ('unknown partner refused', false);
  exception when others then insert into results values ('unknown partner refused', sqlerrm = 'invalid_provider'); end;
  insert into results values ('a refused file writes nothing', (select count(*) from public.product_tables) = v_before);
  begin
    perform public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
      pg_temp.row_of('T Inativa', jsonb_build_object('production_origin', 'third_party', 'provider_id', (select id from made where label = 'inactive')))));
    insert into results values ('inactive partner refused', false);
  exception when others then insert into results values ('inactive partner refused', sqlerrm = 'invalid_provider'); end;
  begin
    perform public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
      pg_temp.row_of('T Contraditoria', jsonb_build_object('production_origin', 'own', 'provider_id', (select id from made where label = 'prov')))));
    insert into results values ('own production with a partner refused', false);
  exception when others then insert into results values ('own production with a partner refused', sqlerrm = 'invalid_production_origin'); end;
  begin
    perform public.import_smart_commercial_rows((select org from ids), 'own', null, null, jsonb_build_array(
      pg_temp.row_of('T Estranha', jsonb_build_object('production_origin', 'outra'))));
    insert into results values ('unknown origin refused', false);
  exception when others then insert into results values ('unknown origin refused', sqlerrm = 'invalid_production_origin'); end;
end $$;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'import row origin contract failed'; end if;
end $$;

rollback;
