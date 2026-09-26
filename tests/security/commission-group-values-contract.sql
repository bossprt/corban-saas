-- Contract test for 20260926010227_commission_group_values_v1 (local test company, see data-scope-contract.sql).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/commission-group-values-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0601'::uuid as grp,
       '00000000-0000-4000-8000-0000000c0501'::uuid as published_condition,
       (select id from public.commission_component_types where tech_key = 'upfront') as upfront,
       (select id from public.commission_component_types where tech_key = 'plastic') as plastic,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.refused(p_sql text, p_error text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm = p_error;
end $$;

-- The conversion: the seed line pays 6% upfront and 14% deferred; the Ouro group had 50% of what the company receives.
-- (The seed is loaded after the migration, so the conversion runs here; running it twice changes nothing.)
insert into results select 'the conversion is repeatable', private.convert_shares_to_group_values((select org from ids)) >= 0 and private.convert_shares_to_group_values((select org from ids)) = 0;
insert into results select 'today''s shares were converted exactly', (select count(*) from public.commercial_condition_group_values
  where condition_id = (select published_condition from ids) and source = 'converted') = 2
  and exists (select 1 from public.commercial_condition_group_values where condition_id = (select published_condition from ids)
    and component_type_id = (select upfront from ids) and value = 3 and value::text = '3')
  and exists (select 1 from public.commercial_condition_group_values where condition_id = (select published_condition from ids) and value::text = '7');

-- A draft line to write on.
insert into public.product_table_versions (id, organization_id, product_table_id, version, status)
values ('00000000-0000-4000-8000-0000000c0399', (select org from ids), '00000000-0000-4000-8000-0000000c0201', 99, 'draft');
select set_config('corban.condition_rpc', 'on', true);
insert into public.commercial_conditions (id, organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, rate)
select '00000000-0000-4000-8000-0000000c0599', (select org from ids), '00000000-0000-4000-8000-0000000c0399', contract_type_id, 12, 12, 12, 1.5
from public.commercial_conditions where id = (select published_condition from ids);
select set_config('corban.condition_rpc', 'off', true);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.replace_condition_group_values('00000000-0000-4000-8000-0000000c0599', jsonb_build_array(
  jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '2.50', 'source', 'import'),
  jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select plastic from ids), 'value_kind', 'fixed_brl', 'value', '25.00')));
insert into results select 'a draft line takes % and R$ values, exact', exists (select 1 from public.commercial_condition_group_values
  where condition_id = '00000000-0000-4000-8000-0000000c0599' and component_type_id = (select upfront from ids) and value::text = '2.5' and source = 'import')
  and exists (select 1 from public.commercial_condition_group_values where condition_id = '00000000-0000-4000-8000-0000000c0599'
  and component_type_id = (select plastic from ids) and value_kind = 'fixed_brl' and value = 25);
insert into results select 'more than 100% is refused', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', '00000000-0000-4000-8000-0000000c0599',
  jsonb_build_array(jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '100.5'))), 'invalid_group_value');
insert into results select 'a non-decimal value is refused', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', '00000000-0000-4000-8000-0000000c0599',
  jsonb_build_array(jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '2e1'))), 'invalid_group_value');
insert into results select 'the same group and type twice is refused', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', '00000000-0000-4000-8000-0000000c0599',
  jsonb_build_array(jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '1'),
                    jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '2'))), 'duplicate_group_value');
insert into results select 'a published line cannot be changed', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', (select published_condition from ids), '[]'), 'version_not_draft');
insert into results select 'values cannot be written directly', pg_temp.refused(format('delete from public.commercial_condition_group_values where condition_id = %L', (select published_condition from ids)),
  'permission denied for table commercial_condition_group_values');
reset role;

-- Own production has no values.
insert into public.commission_groups (id, organization_id, name, kind, calculation_basis) values ('00000000-0000-4000-8000-0000000c0699', (select org from ids), 'Própria Contrato', 'other', 'percent_of_received_commission');
select set_config('corban.group_rule_rpc', 'on', true);
insert into public.commission_group_rules (organization_id, group_id, version, own_production, supervisor_basis, supervisor_pct, manager_basis, manager_pct)
values ((select org from ids), '00000000-0000-4000-8000-0000000c0699', 1, true, 'spread', 0, 'spread', 0);
select set_config('corban.group_rule_rpc', 'off', true);
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'an own-production group gets no values', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', '00000000-0000-4000-8000-0000000c0599',
  jsonb_build_array(jsonb_build_object('group_id', '00000000-0000-4000-8000-0000000c0699', 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '1'))), 'group_is_own_production');
reset role;

insert into results select 'not even the owner changes a published value', pg_temp.refused(format('update public.commercial_condition_group_values set value = 9 where condition_id = %L', (select published_condition from ids)),
  'published_version_values_are_immutable');
insert into results select 'a draft value needs the governed function', pg_temp.refused(format('update public.commercial_condition_group_values set value = 9 where condition_id = %L', '00000000-0000-4000-8000-0000000c0599'),
  'group_values_require_governed_rpc');

-- A new vigência copied from the published one carries its lines and values; saving a line is all or nothing.
-- (the test draft goes away first: a table has one draft at a time, and removing a draft line takes its values along)
delete from public.commercial_conditions where product_table_version_id = '00000000-0000-4000-8000-0000000c0399';
insert into results select 'removing a draft line takes its values along', not exists (select 1 from public.commercial_condition_group_values where condition_id = '00000000-0000-4000-8000-0000000c0599');
delete from public.product_table_versions where id = '00000000-0000-4000-8000-0000000c0399';
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
create temp table cloned as select public.clone_table_version('00000000-0000-4000-8000-0000000c0302') as id;
reset role;
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'a new vigência is a copy of the published one', (select status from public.product_table_versions where id = (select id from cloned)) = 'draft'
  and (select count(*) from public.commercial_condition_group_values v join public.commercial_conditions c on c.id = v.condition_id where c.product_table_version_id = (select id from cloned)) = 2
  and (select count(*) from public.commercial_condition_components k join public.commercial_conditions c on c.id = k.condition_id where c.product_table_version_id = (select id from cloned)) = 2;
insert into results select 'a line is saved all or nothing', pg_temp.refused(format('select public.save_condition_values(%L, %L, %L)',
  (select c.id from public.commercial_conditions c where c.product_table_version_id = (select id from cloned) limit 1),
  jsonb_build_array(jsonb_build_object('component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'received_value', '9', 'source', 'manual')),
  jsonb_build_array(jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select upfront from ids), 'value_kind', 'percentage', 'value', '150'))), 'invalid_group_value')
  and exists (select 1 from public.commercial_condition_components k join public.commercial_conditions c on c.id = k.condition_id
    where c.product_table_version_id = (select id from cloned) and k.component_type_id = (select upfront from ids) and k.received_value = 6);
reset role;

-- A seller neither writes nor reads group values.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller cannot write group values', pg_temp.refused(format('select public.replace_condition_group_values(%L, %L)', '00000000-0000-4000-8000-0000000c0599', '[]'), 'not_authorized');
insert into results select 'a seller does not read group values', not exists (select 1 from public.commercial_condition_group_values);
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if (select count(*) from results) <> 16 or exists (select 1 from results where not ok) then raise exception 'commission group values contract failed'; end if;
end $$;

rollback;
