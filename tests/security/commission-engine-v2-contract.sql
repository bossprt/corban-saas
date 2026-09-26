-- Contract test for 20260926020000_commission_engine_v2 (part C1, ADR-0037): the owner's two real Hope contracts to
-- the cent (tax per table line, IR withheld per bank, seller group values), supervisor on the spread, deferred split,
-- own production, payout above the receipt refused, governed writes, visibility and freezing.
-- Local test company: table "Tabela Teste INSS" (one line, 12-120x), group Ouro, seller bound to vendedor@.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/commission-engine-v2-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000b0001'::uuid as bank,
       '00000000-0000-4000-8000-0000000c0601'::uuid as grp,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from public.commission_component_types where tech_key = 'upfront') as t_up,
       (select id from public.commission_component_types where tech_key = 'deferred') as t_def,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.lines(p_proposal uuid, p_component text, p_part text) returns text language sql as $$
  select string_agg(l.line_kind || '=' || l.amount::text, ' '
                    order by array_position(array['received','tax','ir_withheld','manager','supervisor','originator','company'], l.line_kind))
  from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = p_proposal and c.status = 'active' and l.component_key = p_component and l.part = p_part
$$;
grant execute on function pg_temp.lines(uuid, text, text) to authenticated;
-- Rule items for every active commission type: à vista from the group's own column at p_up %, everything else at p_rest %.
create function pg_temp.items(p_up text, p_rest text, p_ref text default 'own') returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('component', t.tech_key, 'reference', case when t.tech_key = 'upfront' then p_ref else 'own' end, 'group', null,
                                      'pct', case when t.tech_key = 'upfront' then p_up else p_rest end))
  from public.commission_component_types t where t.is_active
$$;
grant execute on function pg_temp.items(text, text, text) to authenticated;
create function pg_temp.line_of(p_version uuid) returns uuid language sql as $$
  select id from public.commercial_conditions where product_table_version_id = p_version
$$;
grant execute on function pg_temp.line_of(uuid) to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
-- Hierarchy: supervisor leads vendedor; admin leads the supervisor.
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select sup_user from ids)), null, (select admin_user from ids), null);
-- Group Ouro: à vista 100% of its own column, the other types 0%; supervisor and manager 0%.
select public.save_seller_group((select org from ids), (select grp from ids), 'Ouro', false, pg_temp.items('100', '0'), 'spread', '0', 'spread', '0');

-- Vigência 3 (Fabiola's line): à vista 9,5% of the net amount, Ouro 6,175%, tax 6%.
insert into made select 'v3', public.clone_table_version((select tv from ids));
insert into results select 'new vigência copies the line tax (0 before)', (select tax_pct = 0 from public.commercial_conditions where id = pg_temp.line_of((select id from made where label = 'v3')));
select public.save_condition_values(pg_temp.line_of((select id from made where label = 'v3')),
  jsonb_build_array(jsonb_build_object('component_type_id', (select t_up from ids), 'value_kind', 'percentage', 'received_value', '9.5', 'calculation_base', 'LIQUIDO', 'source', 'manual')),
  jsonb_build_array(jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select t_up from ids), 'value_kind', 'percentage', 'value', '6.175', 'source', 'manual')),
  '6');
select public.publish_product_table_version((select id from made where label = 'v3'));
insert into results select 'bank tax situation reads the published lines: taxed',
  exists (select 1 from public.bank_tax_situation((select org from ids)) s where s.bank_id = (select bank from ids) and s.taxed_lines = 1 and s.untaxed_lines = 0);
reset role;

-- The seller registers the Fabiola-like contract: R$ 20.000,00, 60x.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Comissão', '68999770009', null, 'manual') u;
insert into made select 'fab', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'v3'), (select seller from ids), 20000, 20000, null, 60, 'ADE-C1-FAB', 'submitted') d;
do $$ begin
  begin
    perform public.calculate_contract_commission((select id from made where label = 'fab'));
    insert into results values ('seller without propostas.edit cannot calculate', false);
  exception when others then insert into results values ('seller without propostas.edit cannot calculate', sqlerrm = 'not_authorized'); end;
end $$;
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.calculate_contract_commission((select id from made where label = 'fab'));
insert into results select 'Fabiola: 1.900,00 received, 6% tax, 1.235,00 to the seller, margin 551,00',
  pg_temp.lines((select id from made where label = 'fab'), 'upfront', 'upfront')
  = 'received=1900.00 tax=114.00 ir_withheld=0.00 manager=0.00 supervisor=0.00 originator=1235.00 company=551.00';
insert into results select 'calc header records group, rule, tax and IR',
  (select mode = 'group_values' and group_id = (select grp from ids) and group_rule_id is not null and tax_rate_pct = 6 and not tax_exempt and ir_withheld_pct = 0
          and seller_id = (select seller from ids) and supervisor_user_id = (select sup_user from ids)
   from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'fab') and status = 'active');

-- Daycoval-like bank: 0,5% IR withheld. Direct writes are refused; the governed function works.
do $$ begin
  begin
    update public.organization_banks set ir_withheld_pct = 3 where id = (select bank from ids);
    insert into results values ('bank IR cannot be written directly', false);
  exception when others then insert into results values ('bank IR cannot be written directly', sqlerrm = 'bank_tax_requires_governed_rpc'); end;
  begin
    perform public.set_bank_ir_withheld((select bank from ids), '101');
    insert into results values ('bank IR above 100% refused', false);
  exception when others then insert into results values ('bank IR above 100% refused', sqlerrm = 'invalid_ir_withheld'); end;
  begin
    perform public.set_condition_tax(pg_temp.line_of((select id from made where label = 'v3')), '5');
    insert into results values ('published line tax cannot change', false);
  exception when others then insert into results values ('published line tax cannot change', sqlerrm = 'version_not_draft'); end;
end $$;
select public.set_bank_ir_withheld((select bank from ids), '0.5');

-- Vigência 4 (Elves's line): à vista 14% net, Ouro 9,1%; diferido 1,2% net, Ouro 0,6% (the rule pays 0% of it); no tax.
insert into made select 'v4', public.clone_table_version((select id from made where label = 'v3'));
insert into results select 'new vigência copies the line tax (6)', (select tax_pct = 6 from public.commercial_conditions where id = pg_temp.line_of((select id from made where label = 'v4')));
do $$ begin
  begin
    perform public.set_condition_tax(pg_temp.line_of((select id from made where label = 'v4')), '101');
    insert into results values ('line tax above 100% refused', false);
  exception when others then insert into results values ('line tax above 100% refused', sqlerrm = 'invalid_tax_pct'); end;
end $$;
select public.save_condition_values(pg_temp.line_of((select id from made where label = 'v4')),
  jsonb_build_array(
    jsonb_build_object('component_type_id', (select t_up from ids), 'value_kind', 'percentage', 'received_value', '14', 'calculation_base', 'LIQUIDO', 'source', 'manual'),
    jsonb_build_object('component_type_id', (select t_def from ids), 'value_kind', 'percentage', 'received_value', '1.2', 'calculation_base', 'LIQUIDO', 'source', 'manual')),
  jsonb_build_array(
    jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select t_up from ids), 'value_kind', 'percentage', 'value', '9.1', 'source', 'manual'),
    jsonb_build_object('group_id', (select grp from ids), 'component_type_id', (select t_def from ids), 'value_kind', 'percentage', 'value', '0.6', 'source', 'manual')),
  '');
select public.publish_product_table_version((select id from made where label = 'v4'));
insert into results select 'bank tax situation follows the newest published vigência: exempt',
  exists (select 1 from public.bank_tax_situation((select org from ids)) s where s.bank_id = (select bank from ids) and s.taxed_lines = 0 and s.untaxed_lines = 1);
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'elv', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'v4'), (select seller from ids), 3872.85, 3872.85, null, 96, 'ADE-C1-ELV', 'submitted') d;
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.calculate_contract_commission((select id from made where label = 'elv'));
insert into results select 'Elves: 542,20 received (542,199 rounded), 0,5% IR, 352,43 to the seller, no tax',
  pg_temp.lines((select id from made where label = 'elv'), 'upfront', 'upfront')
  = 'received=542.20 tax=0.00 ir_withheld=2.71 manager=0.00 supervisor=0.00 originator=352.43 company=187.06';
insert into results select 'deferred: installments add up to 46,47 and the seller gets none of it',
  (select sum(l.amount * l.multiplier) filter (where l.line_kind = 'received') = 46.47
      and coalesce(sum(l.amount) filter (where l.line_kind = 'originator'), 0) = 0
   from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
   where c.proposal_id = (select id from made where label = 'elv') and c.status = 'active' and l.component_key = 'deferred');
insert into results select 'deferred last installment carries the rounding',
  pg_temp.lines((select id from made where label = 'elv'), 'deferred', 'deferred_last')
  = 'received=0.87 tax=0.00 ir_withheld=0.23 manager=0.00 supervisor=0.00 originator=0.00 company=0.64';
insert into results select 'every part adds up to its received amount',
  not exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
              where c.proposal_id in (select id from made where label in ('fab', 'elv')) and c.status = 'active'
              group by c.id, l.component_key, l.part
              having sum(case when l.line_kind = 'received' then l.amount else -l.amount end) <> 0);

-- New rule version: supervisor 10% of the spread (received − payout). Recalculating keeps the history.
select public.save_seller_group((select org from ids), (select grp from ids), 'Ouro', false, pg_temp.items('100', '0'), 'spread', '10', 'spread', '0');
select public.calculate_contract_commission((select id from made where label = 'elv'));
insert into results select 'supervisor on the spread: 10% of 189,77 = 18,98',
  pg_temp.lines((select id from made where label = 'elv'), 'upfront', 'upfront')
  = 'received=542.20 tax=0.00 ir_withheld=2.71 manager=0.00 supervisor=18.98 originator=352.43 company=168.08';
insert into results select 'recalculation keeps history: one active, one superseded',
  (select count(*) filter (where status = 'active') = 1 and count(*) filter (where status = 'superseded') = 1
   from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'elv'));

-- A rule paying 100% of the company value plus 10% of the payout to the supervisor exceeds the receipt: refused.
select public.save_seller_group((select org from ids), (select grp from ids), 'Ouro', false, pg_temp.items('100', '0', 'company'), 'payout', '10', 'spread', '0');
do $$ begin
  begin
    perform public.calculate_contract_commission((select id from made where label = 'elv'));
    insert into results values ('payout above the receipt is refused', false);
  exception when others then insert into results values ('payout above the receipt is refused', sqlerrm = 'payout_exceeds_received'); end;
end $$;

-- Own production: the company keeps everything.
select public.save_seller_group((select org from ids), (select grp from ids), 'Ouro', true, '[]'::jsonb, 'spread', '0', 'spread', '0');
select public.calculate_contract_commission((select id from made where label = 'elv'));
insert into results select 'own production: no payout, margin = received − IR',
  pg_temp.lines((select id from made where label = 'elv'), 'upfront', 'upfront')
  = 'received=542.20 tax=0.00 ir_withheld=2.71 manager=0.00 supervisor=0.00 originator=0.00 company=539.49';
-- Vigência 5 loses the base of the à vista (a % without "bruto" or "líquido"): the calculation refuses to guess.
insert into made select 'v5', public.clone_table_version((select id from made where label = 'v4'));
select public.save_condition_values(pg_temp.line_of((select id from made where label = 'v5')),
  jsonb_build_array(jsonb_build_object('component_type_id', (select t_up from ids), 'value_kind', 'percentage', 'received_value', '14', 'source', 'manual')),
  '[]'::jsonb, '');
select public.publish_product_table_version((select id from made where label = 'v5'));
insert into made select 'nobase', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select id from made where label = 'v5'), (select seller from ids), 1000, 1000, null, 96, 'ADE-C1-NOBASE', 'submitted') d;
do $$ begin
  begin
    perform public.calculate_contract_commission((select id from made where label = 'nobase'));
    insert into results values ('a % without its base is refused', false);
  exception when others then insert into results values ('a % without its base is refused', sqlerrm = 'calculation_base_missing'); end;
end $$;
do $$ begin
  begin
    update public.proposal_commission_lines set amount = 1 where calc_id in (select id from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'elv'));
    insert into results values ('commission lines cannot be edited', not exists (select 1 from public.proposal_commission_lines where amount = 1));
  exception when others then insert into results values ('commission lines cannot be edited', true); end;
end $$;
reset role;

-- Visibility: the seller sees only their own originator lines (never the IR, tax or margin); another seller sees nothing.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'originator does not see the calc header',
  not exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'fab'));
insert into results select 'originator sees only originator lines',
  not exists (select 1 from public.proposal_commission_lines where line_kind <> 'originator')
  and exists (select 1 from public.proposal_commission_lines l where l.line_kind = 'originator' and l.amount = 1235.00);
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'other seller sees no commission',
  not exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
              where c.proposal_id in (select id from made where label in ('fab', 'elv')));
reset role;

-- Paid contracts are frozen.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.move_operational_case((select id from public.operational_cases where proposal_id = (select id from made where label = 'fab')), 'paid', 'Pago ao cliente', null);
do $$ begin
  begin
    perform public.calculate_contract_commission((select id from made where label = 'fab'));
    insert into results values ('paid contract commission is frozen', false);
  exception when others then insert into results values ('paid contract commission is frozen', sqlerrm = 'commission_frozen'); end;
end $$;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'commission engine v2 contract failed'; end if;
end $$;

rollback;
