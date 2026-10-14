-- Contract test for 20261014053535_manual_received_commission_v1: the commission received typed per contract (Gratificação
-- first): % of the net, % of the gross or R$; it enters the calculation at once, the other components stay as the table
-- says; removed with a reason; history kept and never changed; only administrators and managers. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/manual-received-commission-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
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
create function pg_temp.set(p_kind text, p_value text, p_reason text) returns text language sql as $$
  select pg_temp.err(format('select public.set_contract_manual_commission(%L::uuid, %L, %L, %L, %L)', (select id from made where label = 'p'), 'gratification', p_kind, p_value, p_reason))
$$;
grant execute on function pg_temp.set(text, text, text) to authenticated;
create function pg_temp.received(p_component text) returns numeric language sql as $$
  select coalesce(sum(l.amount * l.multiplier), 0) from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
  where c.proposal_id = (select id from made where label = 'p') and c.status = 'active' and l.component_key = p_component and l.line_kind = 'received'
$$;
grant execute on function pg_temp.received(text) to authenticated;

-- A calculated contract: gross 10.000,00, net 9.500,00.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Gratificação', '68999770009', null, 'manual') u;
insert into made select 'p', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-GRAT-1', 'submitted',
  (select ct.id from public.contract_types ct join public.commercial_conditions cc on cc.contract_type_id = ct.id where cc.product_table_version_id = (select tv from ids) limit 1)) d;
set constraints all immediate;
reset role;
create temp table before as select pg_temp.received('upfront') upfront;
grant select on before to authenticated;
insert into results select 'the contract is calculated from the table', (select upfront > 0 from before) and pg_temp.received('gratification') = 0;

-- A seller cannot type it.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot type the commission received', pg_temp.set('brl', '150.00', 'veio do banco') like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'R$ 150,00', pg_temp.set('brl', '150.00', 'Gratificação do banco') = 'ok';
insert into results select 'R$: the contract now receives 150,00 of Gratificação', pg_temp.received('gratification') = 150.00;
insert into results select 'the other components stay as the table says', pg_temp.received('upfront') = (select upfront from before);
insert into results select '2% of the net', pg_temp.set('pct_liquido', '2', 'Gratificação 2% líquido') = 'ok' and pg_temp.received('gratification') = 190.00;
insert into results select '2% of the gross', pg_temp.set('pct_bruto', '2', 'Gratificação 2% bruto') = 'ok' and pg_temp.received('gratification') = 200.00;
insert into results select 'more than 100% is refused', pg_temp.set('pct_liquido', '150', 'erro') like '%invalid_amount%';
insert into results select 'R$ with 3 decimals is refused', pg_temp.set('brl', '1.234', 'erro') like '%invalid_amount%';
insert into results select 'Brazilian format is refused (dot decimal only)', pg_temp.set('brl', '1.234,00', 'erro') like '%invalid_amount%';
insert into results select 'a reason is required', pg_temp.set('brl', '10.00', 'x') like '%reason_required%';
insert into results select 'an unknown component is refused',
  pg_temp.err(format('select public.set_contract_manual_commission(%L::uuid, %L, %L, %L, %L)', (select id from made where label = 'p'), 'nao_existe', 'brl', '10.00', 'erro')) like '%invalid_component%';
insert into results select 'removed with a reason', pg_temp.set('remove', null, 'Banco não pagou') = 'ok' and pg_temp.received('gratification') = 0;
reset role;

insert into results select 'every change is in the history with its reason',
  (select count(*) = 4 from public.contract_events where proposal_id = (select id from made where label = 'p') and kind = 'manual_commission')
  and exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'p') and kind = 'manual_commission' and reason = 'Banco não pagou');
insert into results select 'the typed values are kept (4 rows, the last one removes)',
  (select count(*) = 4 from public.proposal_manual_components where proposal_id = (select id from made where label = 'p'))
  and (select value = 0 from public.proposal_manual_components where proposal_id = (select id from made where label = 'p') order by created_at desc limit 1);
insert into results select 'the history cannot be changed',
  pg_temp.err(format('update public.proposal_manual_components set value = 999 where proposal_id = %L', (select id from made where label = 'p'))) like '%manual_commission_is_immutable%';

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'manual received commission contract failed'; end if;
end $$;
rollback;
