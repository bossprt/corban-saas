-- Contract test for 20260925180643_seller_group_rules_v1 (local test company and users, see data-scope-contract.sql).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/seller-group-rules-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
-- Seven items, one per commission type: the group's own column, 100% (diferido 0%).
create function pg_temp.items(p_ref text, p_group uuid) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('component', tech_key, 'reference', p_ref, 'group', p_group,
    'pct', case when tech_key = 'deferred' then '0' else '100' end) order by sort_order)
  from public.commission_component_types where is_active;
$$;
create function pg_temp.refused(p_sql text, p_error text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm = p_error;
end $$;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'balcao', public.save_seller_group((select org from ids), null, 'Balcão Contrato', false, pg_temp.items('own', null), 'spread', '5', 'production', '1.25');
insert into results select 'admin creates a group with its rule', exists (
  select 1 from public.commission_group_rules r where r.group_id = (select id from made where label = 'balcao') and r.version = 1
    and r.supervisor_pct = 5 and r.manager_basis = 'production' and r.manager_pct = 1.25);
insert into results select 'the rule has one item per commission type', (select count(*) from public.commission_group_rule_items i
  join public.commission_group_rules r on r.id = i.rule_id where r.group_id = (select id from made where label = 'balcao'))
  = (select count(*) from public.commission_component_types where is_active);
insert into made select 'externos', public.save_seller_group((select org from ids), null, 'Externos Contrato', false,
  pg_temp.items('group', (select id from made where label = 'balcao')), 'payout', '0', 'spread', '0');
insert into results select 'a rule can read another group''s column', exists (select 1 from public.commission_group_rule_items i
  join public.commission_group_rules r on r.id = i.rule_id where r.group_id = (select id from made where label = 'externos')
    and i.reference_kind = 'group' and i.reference_group_id = (select id from made where label = 'balcao'));
select public.save_seller_group((select org from ids), (select id from made where label = 'balcao'), 'Balcão Contrato', false, pg_temp.items('company', null), 'spread', '5', 'production', '2');
insert into results select 'an edit is a new version; the old one stays', (select count(*) from public.commission_group_rules where group_id = (select id from made where label = 'balcao')) = 2
  and exists (select 1 from public.commission_group_rules where group_id = (select id from made where label = 'balcao') and version = 1 and manager_pct = 1.25);
insert into made select 'propria', public.save_seller_group((select org from ids), null, 'Produção Própria Contrato', true, '[]'::jsonb, 'spread', '0', 'spread', '3');
insert into results select 'own production has no payout items', exists (select 1 from public.commission_group_rules where group_id = (select id from made where label = 'propria') and own_production)
  and not exists (select 1 from public.commission_group_rule_items i join public.commission_group_rules r on r.id = i.rule_id where r.group_id = (select id from made where label = 'propria'));

insert into results select 'incomplete rule is refused', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  (select org from ids), 'Incompleto', '[{"component":"upfront","reference":"own","group":null,"pct":"100"}]', 'spread', '0', 'spread', '0'), 'rule_items_incomplete');
insert into results select 'more than 100% is refused', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  (select org from ids), 'Acima', replace(pg_temp.items('own', null)::text, '"100"', '"100.5"'), 'spread', '0', 'spread', '0'), 'invalid_rule_pct');
insert into results select 'a non-decimal percentage is refused', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  (select org from ids), 'Float', pg_temp.items('own', null)::text, 'spread', '1e2', 'spread', '0'), 'invalid_hierarchy_pct');
insert into results select 'own production with payout items is refused', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, true, %L, %L, %L, %L, %L)',
  (select org from ids), 'Própria Errada', pg_temp.items('own', null)::text, 'spread', '0', 'spread', '0'), 'own_production_has_no_payout');
insert into results select 'an own-production group cannot be read as a column', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  (select org from ids), 'Lê Própria', pg_temp.items('group', (select id from made where label = 'propria'))::text, 'spread', '0', 'spread', '0'), 'invalid_reference_group');
insert into results select 'a column other rules read cannot become own production', pg_temp.refused(format('select public.save_seller_group(%L, %L, %L, true, %L, %L, %L, %L, %L)',
  (select org from ids), (select id from made where label = 'balcao'), 'Balcão Contrato', '[]', 'spread', '0', 'spread', '0'), 'group_column_in_use');
insert into results select 'another company is refused', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  gen_random_uuid(), 'Outra', pg_temp.items('own', null)::text, 'spread', '0', 'spread', '0'), 'not_authorized');
insert into results select 'rules cannot be changed directly', pg_temp.refused('update public.commission_group_rules set manager_pct = 50', 'commission_group_rule_immutable')
  or pg_temp.refused('update public.commission_group_rules set manager_pct = 50', 'permission denied for table commission_group_rules');
reset role;

insert into results select 'not even the owner edits a rule in place', pg_temp.refused('delete from public.commission_group_rule_items', 'commission_group_rule_immutable');
insert into results select 'no direct insert without the governed function', pg_temp.refused(format(
  'insert into public.commission_group_rules (organization_id, group_id, version, supervisor_basis, supervisor_pct, manager_basis, manager_pct) values (%L, %L, 9, %L, 0, %L, 0)',
  (select org from ids), (select id from made where label = 'balcao'), 'spread', 'spread'), 'commission_group_rule_requires_governed_rpc');

-- A seller neither writes nor reads payout rules.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller cannot save a group', pg_temp.refused(format('select public.save_seller_group(%L, null, %L, false, %L, %L, %L, %L, %L)',
  (select org from ids), 'Vendedor', pg_temp.items('own', null)::text, 'spread', '0', 'spread', '0'), 'not_authorized');
insert into results select 'a seller does not see payout rules', not exists (select 1 from public.commission_group_rules)
  and not exists (select 1 from public.commission_group_rule_items);
reset role;

insert into results select 'the old second grouping of sellers is gone', to_regclass('public.seller_groups') is null
  and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'commercial_sellers' and column_name = 'seller_group_id');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if (select count(*) from results) <> 18 or exists (select 1 from results where not ok) then raise exception 'seller group rules contract failed'; end if;
end $$;

rollback;
