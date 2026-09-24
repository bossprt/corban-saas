-- Contract test for 20260927090000_commission_engine_v1: the owner-approved example to the cent, both modes,
-- precedence, exemption, deferred opt-out, visibility and immutability. Local test company with the commission seed
-- (condition 6% upfront + 14% deferred on the gross amount, group Ouro 50%, seller bound to vendedor@).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/commission-engine-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0201'::uuid as tbl,
       '00000000-0000-4000-8000-0000000b0001'::uuid as bank,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
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
-- Lines of the active calc of a proposal as 'part:kind=amount' sorted, for exact comparison.
create function pg_temp.lines(p_proposal uuid, p_component text, p_part text) returns text language sql as $$
  select string_agg(l.line_kind || '=' || l.amount::text, ' ' order by array_position(array['received','tax','manager','supervisor','originator','company'], l.line_kind))
  from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = p_proposal and c.status = 'active' and l.component_key = p_component and l.part = p_part
$$;
grant execute on function pg_temp.lines(uuid, text, text) to authenticated;

-- Hierarchy: supervisor leads vendedor; admin leads the supervisor (manager of the sale).
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select sup_user from ids)), null, (select admin_user from ids), null);
-- Owner rule: cascade, tax 6%, profit 40%, manager 10 / supervisor 15 / originator 75, deferred paid to the team.
select public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 10, 15, 75, true, 'regra do exemplo');
reset role;

-- The seller registers the client and the proposal (R$ 10.000,00 gross, 120 installments) with the seller bound.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Comissão', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-COM-1', 'submitted') d;
do $$ begin
  begin
    perform public.calculate_proposal_commission((select id from made where label = 'p'));
    insert into results values ('seller without propostas.edit cannot calculate', false);
  exception when others then insert into results values ('seller without propostas.edit cannot calculate', sqlerrm = 'not_authorized'); end;
end $$;
reset role;

-- Finance calculates.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.calculate_proposal_commission((select id from made where label = 'p'));
insert into results select 'cascade upfront = approved example',
  pg_temp.lines((select id from made where label = 'p'), 'upfront', 'upfront') = 'received=600.00 tax=36.00 manager=33.84 supervisor=50.76 originator=253.80 company=225.60';
insert into results select 'cascade deferred standard installment (x119)',
  pg_temp.lines((select id from made where label = 'p'), 'deferred', 'deferred_standard') = 'received=11.67 tax=0.70 manager=0.66 supervisor=0.99 originator=4.94 company=4.38';
insert into results select 'cascade deferred last installment (residual)',
  pg_temp.lines((select id from made where label = 'p'), 'deferred', 'deferred_last') = 'received=11.27 tax=0.68 manager=0.64 supervisor=0.95 originator=4.76 company=4.24';
insert into results select 'deferred installments add up to 1.400,00',
  (select sum(l.amount * l.multiplier) from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
   where c.proposal_id = (select id from made where label = 'p') and c.status = 'active' and l.component_key = 'deferred' and l.line_kind = 'received') = 1400.00;
insert into results select 'every part adds up to its received amount',
  not exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
              where c.proposal_id = (select id from made where label = 'p') and c.status = 'active'
              group by l.component_key, l.part
              having sum(case when l.line_kind = 'received' then l.amount else -l.amount end) <> 0);
insert into results select 'beneficiaries frozen from the hierarchy',
  (select originator_user_id = (select v1 from ids) and supervisor_user_id = (select sup_user from ids) and manager_user_id = (select admin_user from ids)
   from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p') and status = 'active');

-- Table-level rule switches this bank table to group_table (manager 3%, supervisor 5% of the base): precedence.
select public.save_commission_rule((select org from ids), 'table', (select tbl from ids), 'group_table', null, null, 3, 5, null, null, null);
select public.calculate_proposal_commission((select id from made where label = 'p'));
insert into results select 'group table upfront = approved example',
  pg_temp.lines((select id from made where label = 'p'), 'upfront', 'upfront') = 'received=600.00 tax=36.00 manager=16.92 supervisor=28.20 originator=282.00 company=236.88';
insert into results select 'recalculation keeps history: one active, one superseded',
  (select count(*) filter (where status = 'active') = 1 and count(*) filter (where status = 'superseded') = 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p'));

-- Seller rule: deferred not paid to the team -> the whole deferred base stays with the company.
select public.save_commission_rule((select org from ids), 'seller', (select seller from ids), null, null, null, null, null, null, false, null);
select public.calculate_proposal_commission((select id from made where label = 'p'));
insert into results select 'deferred opt-out: team gets nothing from the deferred',
  pg_temp.lines((select id from made where label = 'p'), 'deferred', 'deferred_standard') = 'received=11.67 tax=0.70 manager=0.00 supervisor=0.00 originator=0.00 company=10.97';
insert into results select 'upfront is still paid to the team', pg_temp.lines((select id from made where label = 'p'), 'upfront', 'upfront') like '%originator=282.00%';
reset role;

-- Exempt paying bank -> no tax (set as the owner of the check).
update public.organization_banks set tax_exempt = true where id = (select bank from ids);
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.calculate_proposal_commission((select id from made where label = 'p'));
insert into results select 'exempt bank: no tax on the upfront', pg_temp.lines((select id from made where label = 'p'), 'upfront', 'upfront') like 'received=600.00 tax=0.00 %';
do $$ begin
  begin
    update public.proposal_commission_lines set amount = 1 where calc_id in (select id from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p'));
    insert into results values ('commission lines cannot be edited', not exists (select 1 from public.proposal_commission_lines where amount = 1));
  exception when others then insert into results values ('commission lines cannot be edited', true); end;
  begin
    perform public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 50, 40, 30, true, null);
    insert into results values ('cascade split above 100% is refused', false);
  exception when others then insert into results values ('cascade split above 100% is refused', true); end;
end $$;
reset role;

-- Visibility: the seller sees only his own originator lines; another seller sees nothing.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'originator sees his calc', exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p') and status = 'active');
insert into results select 'originator sees only originator lines', not exists (select 1 from public.proposal_commission_lines where line_kind <> 'originator')
  and exists (select 1 from public.proposal_commission_lines where line_kind = 'originator');
reset role;
select pg_temp.act_as((select v2 from ids));
set local role authenticated;
insert into results select 'other seller sees no commission', not exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p'))
  and not exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id where c.proposal_id = (select id from made where label = 'p'));
reset role;

-- Paid proposals are frozen.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.move_operational_case((select id from public.operational_cases where proposal_id = (select id from made where label = 'p')), 'paid', 'Pago no portal', null);
do $$ begin
  begin
    perform public.calculate_proposal_commission((select id from made where label = 'p'));
    insert into results values ('paid proposal commission is frozen', false);
  exception when others then insert into results values ('paid proposal commission is frozen', sqlerrm = 'commission_frozen'); end;
end $$;
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'commission engine contract failed'; end if;
end $$;

rollback;
