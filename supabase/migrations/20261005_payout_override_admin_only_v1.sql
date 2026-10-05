-- Payout changes are the owner's alone (owner request 05/10/2026). Changing what a seller receives for a contract, and
-- even knowing that it was changed, is restricted to the Administrador:
--   * set_payout_override: admin only (was admin or manager);
--   * contract_payout / contract_payout_totals: other finance roles see the payable amount as the amount, with no
--     "rule" behind it and no "overridden" flag;
--   * contract_payout_overrides and the payout_override* contract events: readable by admin only;
--   * proposal_commission_mine: the seller (and the broker in the portal) gets only what they will receive, never the
--     amount by the rule, so a lowered payout cannot be noticed from the seller side.
--   * proposal_commission_lines: finance only (the seller read their own lines, the amounts by the rule).
-- No data is changed; overrides already recorded stay as they are.

create or replace function public.set_payout_override(p_proposal uuid, p_component text, p_kind text, p_value text, p_reason text)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  p public.proposals_v2%rowtype;
  x record;
  v_value numeric;
  v_payable numeric;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.has_active_organization_role(p.organization_id, array['admin'])
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 500 then raise exception 'reason_required'; end if;
  select * into x from private.contract_payable(p.id) c where c.component_key = p_component;
  if x.component_key is null then raise exception 'commission_not_calculated'; end if;

  if p_kind is null then
    if not x.overridden then return; end if;
    v_payable := x.rule_amount;
  else
    if p_kind not in ('percentage', 'fixed_brl') or coalesce(p_value, '') !~ '^[0-9]{1,9}(\.[0-9]{1,8})?$' then raise exception 'invalid_override'; end if;
    v_value := trim_scale(p_value::numeric);
    if p_kind = 'percentage' and v_value > 100 then raise exception 'invalid_override'; end if;
    v_payable := case when p_kind = 'fixed_brl' then round(v_value, 2) else round(coalesce(x.base_amount, 0) * v_value / 100, 2) end;
    if v_payable > x.received then raise exception 'override_exceeds_received'; end if;
  end if;

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_payout_overrides (organization_id, proposal_id, component_key, value_kind, value, reason, created_by)
  values (p.organization_id, p.id, p_component, p_kind, v_value, btrim(p_reason), auth.uid());
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, case when p_kind is null then 'payout_override_cleared' else 'payout_override' end,
          jsonb_build_object('component', p_component, 'rule_amount', x.rule_amount, 'previous', x.payable, 'payable', v_payable,
                             'value_kind', p_kind, 'value', v_value), btrim(p_reason), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$function$;

create or replace function public.contract_payout(p_proposal uuid)
 returns table(component_key text, received numeric, rule_amount numeric, base_amount numeric, value_kind text, value numeric, payable numeric, overridden boolean, locked boolean)
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare p public.proposals_v2%rowtype; v_admin boolean;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.has_permission(p.organization_id, 'financeiro.view')
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  v_admin := public.has_active_organization_role(p.organization_id, array['admin']);
  return query
    select x.component_key, x.received, case when v_admin then x.rule_amount else x.payable end, x.base_amount,
           case when v_admin then x.value_kind end, case when v_admin then x.value end, x.payable, v_admin and x.overridden,
           private.contract_payout_received(p.id)
    from private.contract_payable(p.id) x order by x.component_key;
end
$function$;

create or replace function public.contract_payout_totals(p_org uuid)
 returns table(proposal_id uuid, received numeric, rule_amount numeric, payable numeric, overridden boolean, waiting text, credited numeric, paid_on date)
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v_admin boolean;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  v_admin := public.has_active_organization_role(p_org, array['admin']);
  return query
    select c.proposal_id, sum(x.received), case when v_admin then sum(x.rule_amount) else sum(x.payable) end, sum(x.payable),
           v_admin and bool_or(x.overridden), s.waiting, s.credited, s.paid_on
    from public.proposal_commission_calcs c
    cross join lateral private.contract_payable(c.proposal_id) x
    cross join lateral private.contract_credit_state(c.proposal_id) s
    where c.organization_id = p_org and c.status = 'active'
    group by c.proposal_id, s.waiting, s.credited, s.paid_on;
end
$function$;

create or replace function public.proposal_commission_mine(p_proposal uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare p public.proposals_v2%rowtype; c public.proposal_commission_calcs%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then
    raise exception 'not_authorized';
  end if;
  select * into c from public.proposal_commission_calcs where proposal_id = p.id and status = 'active';
  if c.id is null then return jsonb_build_object('calculated', false); end if;
  if not private.is_commission_originator(c.id) then
    return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', false);
  end if;
  return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', true,
    'payable', coalesce((select jsonb_agg(jsonb_build_object('component_key', x.component_key, 'amount', x.payable::text) order by x.component_key)
              from private.contract_payable(p.id) x where x.payable > 0), '[]'::jsonb));
end
$function$;

drop policy contract_payout_overrides_select on public.contract_payout_overrides;
create policy contract_payout_overrides_select on public.contract_payout_overrides for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin']));

drop policy contract_events_select on public.contract_events;
create policy contract_events_select on public.contract_events for select to authenticated
  using (exists (select 1 from public.proposals_v2 p where p.id = proposal_id and p.organization_id = contract_events.organization_id
                 and public.is_active_organization_member(p.organization_id) and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by))
         and (kind in ('edit', 'note', 'recalculated', 'calc_failed', 'physical')
              or (kind like 'payout_override%' and public.has_active_organization_role(organization_id, array['admin']))
              or (kind not like 'payout_override%' and public.has_permission(organization_id, 'financeiro.view'))));

-- The seller no longer reads their own commission lines straight from the table: those lines are the amount by the
-- rule, which would show a lowered payout. Their share comes only from proposal_commission_mine (payable).
drop policy proposal_commission_lines_select on public.proposal_commission_lines;
create policy proposal_commission_lines_select on public.proposal_commission_lines for select to authenticated
  using (public.has_permission(organization_id, 'financeiro.view')
         and exists (select 1 from public.proposal_commission_calcs c where c.id = proposal_commission_lines.calc_id));
