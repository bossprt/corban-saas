-- The owner's dashboard (owner request 06/10/2026), one call: the numbers of a period and of the period just before it
-- (for "+18% vs anterior"; by default the same number of days just before, or the range the screen passes, e.g. the
-- same days of the previous month), what needs attention, production per day (or month), sellers, banks and the pipeline.
-- Every figure comes from the contracts and money already in Corban; amounts stay numeric (never float).
--   * production: contracts paid to the client in the period (paid_to_client_on), the amount released to the client;
--   * expected commission: what the bank pays for those contracts by the table (the active calculation);
--   * received: bank commission received in the period (receipts minus chargebacks, received_on);
--   * company margin: expected commission minus tax, IR, supervisor, manager and what is payable to the seller
--     (a payout change counts as the owner made it);
--   * attention: bank commission late (client paid more than 30 days ago), divergent commission, sellers to pay,
--     commissions out of date, paid contracts without a calculation, overdue pipeline cases.
-- Finance only (financeiro.view), for the caller's company. Read only.

create or replace function public.owner_dashboard(p_org uuid, p_from date, p_to date, p_prev_from date default null, p_prev_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_days int;
  v_prev_from date;
  v_prev_to date;
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_by_month boolean;
  v_result jsonb;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) or not public.has_permission(p_org, 'financeiro.view') then
    raise exception 'not_authorized';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'invalid_period'; end if;
  v_days := p_to - p_from + 1;
  v_prev_to := coalesce(p_prev_to, p_from - 1);
  v_prev_from := coalesce(p_prev_from, p_from - v_days);
  if v_prev_to < v_prev_from or v_prev_to >= p_from or v_prev_to - v_prev_from > 400 then raise exception 'invalid_period'; end if;
  v_by_month := v_days > 62;

  with contracts as (
    select p.id, p.seller_id, p.paid_to_client_on as paid_on, coalesce(p.released_amount, p.requested_amount, 0) as amount,
           r.org_bank_id as bank_id,
           c.id as calc_id
    from public.proposals_v2 p
    left join public.product_table_versions v on v.id = p.product_table_version_id
    left join public.product_tables t on t.id = v.product_table_id
    left join public.organization_product_routes r on r.id = t.route_id
    left join public.proposal_commission_calcs c on c.proposal_id = p.id and c.status = 'active'
    where p.organization_id = p_org and p.status = 'paid'
      and (p.paid_to_client_on between p_from and p_to or p.paid_to_client_on between v_prev_from and v_prev_to)
  ),
  money as (
    select k.*, (k.paid_on >= p_from) as current,
           coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = k.calc_id and l.line_kind = 'received'), 0) as expected,
           coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = k.calc_id and l.line_kind in ('tax', 'ir_withheld', 'supervisor', 'manager')), 0) as costs,
           coalesce((select sum(x.payable) from private.contract_payable(k.id) x), 0) as payable,
           coalesce((select sum(case when cr.entry_kind = 'chargeback' then -cr.amount else cr.amount end) from public.commission_receipts cr where cr.proposal_id = k.id), 0) as received_all
    from contracts k
  ),
  kpi as (
    select current,
           count(*) as contracts, sum(amount) as production, sum(expected) as expected,
           sum(expected - costs - payable) as margin, sum(payable) as sellers
    from money group by current
  ),
  receipts as (
    select (cr.received_on >= p_from) as current, sum(case when cr.entry_kind = 'chargeback' then -cr.amount else cr.amount end) as received
    from public.commission_receipts cr
    where cr.organization_id = p_org and (cr.received_on between p_from and p_to or cr.received_on between v_prev_from and v_prev_to)
    group by 1
  ),
  open_contracts as (
    select p.id, p.paid_to_client_on, st.waiting,
           coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_calcs c join public.proposal_commission_lines l on l.calc_id = c.id
                     where c.proposal_id = p.id and c.status = 'active' and l.line_kind = 'received'), 0) as expected
    from public.proposals_v2 p cross join lateral private.contract_credit_state(p.id) st
    where p.organization_id = p_org and p.status = 'paid'
  ),
  to_pay as (
    select count(*) as n, coalesce(sum(x.amount), 0) as amount
    from (select private.pay_now_amount(a.id) as amount from public.payout_accounts a
          where a.organization_id = p_org and not private.is_payout_holder(a.id)) x
    where x.amount > 0
  ),
  stale as (
    select count(*) as n from public.proposals_v2 p
    join public.proposal_commission_calcs c on c.proposal_id = p.id and c.status = 'active'
    left join public.commercial_sellers s on s.id = p.seller_id
    where p.organization_id = p_org and (c.seller_id is distinct from p.seller_id or c.group_id is distinct from s.commission_group_id)
  ),
  series as (
    select case when v_by_month then date_trunc('month', paid_on)::date else paid_on end as day, sum(amount) as production, count(*) as contracts
    from money where current group by 1
  ),
  sellers as (
    select m.seller_id, coalesce(s.name, 'Sem vendedor') as name, count(*) as contracts, sum(m.amount) as production, sum(m.payable) as payable
    from money m left join public.commercial_sellers s on s.id = m.seller_id
    where m.current group by 1, 2 order by sum(m.amount) desc limit 8
  ),
  banks as (
    select m.bank_id, coalesce(b.name, 'Sem banco') as name, count(*) as contracts, sum(m.amount) as production,
           sum(m.expected) as expected, sum(greatest(m.expected - m.received_all, 0)) as missing
    from money m left join public.organization_banks b on b.id = m.bank_id
    where m.current group by 1, 2 order by sum(m.amount) desc
  ),
  pipeline as (
    select s.canonical_state as state, count(*) as n
    from public.operational_cases oc join public.operational_stages s on s.id = oc.current_stage_id
    where oc.organization_id = p_org and s.canonical_state not in ('paid', 'cancelled', 'rejected')
    group by 1
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'prev_from', v_prev_from, 'prev_to', v_prev_to, 'by_month', v_by_month),
    'current', (select jsonb_build_object('contracts', coalesce(k.contracts, 0), 'production', coalesce(k.production, 0), 'expected', coalesce(k.expected, 0),
                                          'margin', coalesce(k.margin, 0), 'sellers', coalesce(k.sellers, 0),
                                          'received', coalesce((select received from receipts where current), 0))
                from (select 1) d left join kpi k on k.current),
    'previous', (select jsonb_build_object('contracts', coalesce(k.contracts, 0), 'production', coalesce(k.production, 0), 'expected', coalesce(k.expected, 0),
                                           'margin', coalesce(k.margin, 0), 'sellers', coalesce(k.sellers, 0),
                                           'received', coalesce((select received from receipts where not current), 0))
                 from (select 1) d left join kpi k on not k.current),
    'attention', jsonb_build_object(
      'bank_late', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(expected), 0)) from open_contracts where waiting = 'bank' and paid_to_client_on < v_today - 30),
      'bank_waiting', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(expected), 0)) from open_contracts where waiting = 'bank'),
      'divergent', (select jsonb_build_object('n', count(*)) from open_contracts where waiting = 'divergent'),
      'no_calc', (select jsonb_build_object('n', count(*)) from open_contracts where waiting = 'calculation'),
      'to_pay', (select jsonb_build_object('n', n, 'amount', amount) from to_pay),
      'stale', (select jsonb_build_object('n', n) from stale),
      'overdue', (select jsonb_build_object('n', count(*)) from public.operational_cases oc
                  where oc.organization_id = p_org and oc.canonical_state not in ('paid', 'cancelled', 'rejected') and oc.due_at < now())),
    'series', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'production', production, 'contracts', contracts) order by day) from series), '[]'::jsonb),
    'sellers', coalesce((select jsonb_agg(jsonb_build_object('id', seller_id, 'name', name, 'contracts', contracts, 'production', production, 'payable', payable)) from sellers), '[]'::jsonb),
    'banks', coalesce((select jsonb_agg(jsonb_build_object('id', bank_id, 'name', name, 'contracts', contracts, 'production', production, 'expected', expected, 'missing', missing)) from banks), '[]'::jsonb),
    'pipeline', coalesce((select jsonb_object_agg(state, n) from pipeline), '{}'::jsonb)
  ) into v_result;
  return v_result;
end
$$;
revoke all on function public.owner_dashboard(uuid, date, date, date, date) from public, anon;
grant execute on function public.owner_dashboard(uuid, date, date, date, date) to authenticated;
