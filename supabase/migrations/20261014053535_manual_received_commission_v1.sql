-- Commission received typed per contract (owner request 14/10/2026): "a que a empresa vai receber deverá ter a opção
-- % ou R$ e basicamente sempre será manual" (first: Gratificação). What the seller gets stays programmed in the table
-- (group values), as for every component.
--
-- * proposal_manual_components: append-only history of what was typed for one contract and one component: % of the net
--   amount, % of the gross amount, or R$ (owner: "escolher na hora, contrato por contrato"), with the reason. The latest
--   row of a contract and component is the one in force; a row with value 0 removes it. Never updated or deleted.
-- * private.contract_commission_core: a component in force for the contract replaces the received value of the table
--   line (or adds the component when the line does not have it). The seller's share keeps reading the table's group
--   values; their % base is the line's base for that component, else the base typed, else the net amount.
-- * public.set_contract_manual_commission: administrators and managers; refused on a rejected or cancelled contract
--   and once the seller was paid. Records the history (contract_events "manual_commission") and recalculates; if the
--   new calculation cannot be made (e.g. the seller's share would exceed what is received), nothing is saved.

create table public.proposal_manual_components (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  proposal_id uuid not null references public.proposals_v2(id) on delete restrict,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  value_kind text not null check (value_kind in ('percentage', 'fixed_brl')),
  base text check (base in ('BRUTO', 'LÍQUIDO')),
  value numeric(15,4) not null check (value >= 0),
  reason text not null check (length(btrim(reason)) between 3 and 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  constraint proposal_manual_components_base check ((value_kind = 'percentage') = (base is not null)),
  constraint proposal_manual_components_pct check (value_kind <> 'percentage' or value <= 100),
  constraint proposal_manual_components_brl check (value_kind <> 'fixed_brl' or value = round(value, 2))
);
create index proposal_manual_components_lookup on public.proposal_manual_components (proposal_id, component_type_id, created_at desc);

create or replace function private.guard_manual_component_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op <> 'INSERT' then raise exception 'manual_commission_is_immutable'; end if;
  if current_setting('corban.manual_commission_rpc', true) is distinct from 'on' then raise exception 'manual_commission_requires_governed_rpc'; end if;
  return new;
end
$$;
create trigger proposal_manual_components_00_guard before insert or update or delete on public.proposal_manual_components
  for each row execute function private.guard_manual_component_write();

alter table public.proposal_manual_components enable row level security;
revoke all on table public.proposal_manual_components from anon, authenticated;
grant select on public.proposal_manual_components to authenticated;
create policy proposal_manual_components_select on public.proposal_manual_components for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']) or public.has_permission(organization_id, 'financeiro.view'));

alter table public.contract_events drop constraint contract_events_kind_check;
alter table public.contract_events add constraint contract_events_kind_check check (kind = any (array[
  'edit', 'note', 'recalculated', 'payout_override', 'payout_override_cleared', 'calc_failed', 'physical', 'external_payout', 'manual_commission']));

-- The engine, as in production, with the component loop reading the manual entries in force.
create or replace function private.contract_commission_core(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  p public.proposals_v2%rowtype;
  v_org uuid;
  v_cond public.commercial_conditions%rowtype;
  v_count integer;
  v_bank uuid;
  v_ir numeric;
  v_seller public.commercial_sellers%rowtype;
  v_rule public.commission_group_rules%rowtype;
  it public.commission_group_rule_items%rowtype;
  v_orig uuid; v_sup uuid; v_mgr uuid;
  v_gross numeric; v_net numeric;
  v_pay_deferred boolean;
  v_calc uuid;
  c record;
  v_base numeric; v_pbase numeric; v_received numeric; v_ref numeric;
  v_o numeric; v_s numeric; v_m numeric; v_t numeric; v_i numeric;
begin
  select * into p from public.proposals_v2 where id = p_proposal_id for update;
  v_org := p.organization_id;
  if v_org is null then raise exception 'proposal_not_found'; end if;
  -- A paid contract can still be recalculated (it may be edited until the seller receives); a rejected or cancelled
  -- one keeps its last calculation; nothing moves once the seller received the commission.
  if p.status in ('rejected', 'cancelled') and exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then
    raise exception 'commission_frozen';
  end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;

  -- Line of the table: explicit, or the only one of the contract's table version matching the term and amount (the
  -- amount of the line's base: released for a net line, the contract's amount for a gross one).
  if p_condition_id is not null then
    select * into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond.id is null then raise exception 'condition_not_found'; end if;
  else
    -- A recalculation keeps the line used before while it still fits the contract (type, term, amount).
    select k.* into v_cond from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
    where x.proposal_id = p.id and x.status = 'active' and k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and private.condition_amount_fits(k.id, k.amount_min, k.amount_max, p.requested_amount, p.released_amount);
    if v_cond.id is null then
      -- Else the only line of the table version for the contract's type (when set), term and amount.
      select count(*) into v_count from public.commercial_conditions k
      where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
        and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
        and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
        and private.condition_amount_fits(k.id, k.amount_min, k.amount_max, p.requested_amount, p.released_amount);
      if v_count = 0 then raise exception 'condition_not_found'; end if;
      if v_count > 1 then raise exception 'condition_ambiguous'; end if;
      select * into v_cond from public.commercial_conditions k
      where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
        and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
        and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
        and private.condition_amount_fits(k.id, k.amount_min, k.amount_max, p.requested_amount, p.released_amount);
    end if;
  end if;

  -- IR withheld: the value set for the contract's origin (route), else the bank's for own production and 0 through a
  -- promoter. Fields the owner fills; nothing is assumed (ADR-0049).
  select coalesce(r.ir_withheld_pct, case when r.production_origin = 'third_party' then 0 else b.ir_withheld_pct end, 0) into v_ir
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id
  where v.id = p.product_table_version_id;
  v_ir := coalesce(v_ir, 0);

  -- Seller: the contract's, or the seller linked to whoever registered it. Their group decides the payout.
  if p.seller_id is not null then
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.id = p.seller_id;
  else
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.user_id = p.created_by and s.is_active order by s.created_at limit 1;
  end if;
  if v_seller.id is null then raise exception 'proposal_without_seller'; end if;
  if v_seller.commission_group_id is null then raise exception 'seller_without_group'; end if;
  select * into v_rule from public.commission_group_rules r where r.organization_id = v_org and r.group_id = v_seller.commission_group_id order by r.version desc limit 1;
  if v_rule.id is null then raise exception 'group_rule_missing'; end if;

  -- Supervisor = team leader of the seller's login; manager = the supervisor's leader. A seller without login has no
  -- hierarchy: those shares stay with the company.
  v_orig := v_seller.user_id;
  if v_orig is not null then
    select m.team_leader_user_id into v_sup from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_orig and m.status = 'active';
    if v_sup is not null then
      select m.team_leader_user_id into v_mgr from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_sup and m.status = 'active';
    end if;
  end if;

  v_gross := coalesce(p.requested_amount, p.released_amount, 0);
  v_net := coalesce(p.released_amount, p.requested_amount, 0);
  v_pay_deferred := not v_rule.own_production and exists (
    select 1 from public.commission_group_rule_items i join public.commission_component_types t on t.id = i.component_type_id
    where i.rule_id = v_rule.id and t.tech_key = 'deferred' and i.distributed_pct > 0);

  perform set_config('corban.commission_rpc', 'on', true);
  update public.proposal_commission_calcs set status = 'superseded' where proposal_id = p.id and status = 'active';
  insert into public.proposal_commission_calcs (organization_id, proposal_id, condition_id, mode, tax_rate_pct, tax_exempt, manager_pct, supervisor_pct,
    pay_deferred, gross_amount, net_amount, installments, originator_user_id, supervisor_user_id, manager_user_id, seller_id, rule_ids, calculated_by,
    group_id, group_rule_id, ir_withheld_pct)
  values (v_org, p.id, v_cond.id, 'group_values', v_cond.tax_pct, v_cond.tax_pct = 0, v_rule.manager_pct, v_rule.supervisor_pct,
    v_pay_deferred, v_gross, v_net, p.term, v_orig, v_sup, v_mgr, v_seller.id, array[v_rule.id], auth.uid(),
    v_seller.commission_group_id, v_rule.id, v_ir)
  returning id into v_calc;

  -- Components: the table line's, with the received value typed for this contract (in force, value above 0) replacing
  -- the table's; a component typed for the contract and absent from the line is added.
  for c in
    select t.id as type_id, t.tech_key,
           case when m.value > 0 then m.value_kind else k.value_kind end as value_kind,
           case when m.value > 0 then m.value else k.received_value end as received_value,
           case when m.value > 0 then coalesce(m.base, k.calculation_base, 'LÍQUIDO') else k.calculation_base end as calculation_base,
           coalesce(nullif(btrim(coalesce(k.calculation_base, '')), ''), m.base, 'LÍQUIDO') as payout_base
    from public.commission_component_types t
    left join public.commercial_condition_components k on k.condition_id = v_cond.id and k.component_type_id = t.id
    left join lateral (select x.value_kind, x.base, x.value from public.proposal_manual_components x
                       where x.proposal_id = p.id and x.component_type_id = t.id order by x.created_at desc, x.id desc limit 1) m on true
    where k.condition_id is not null or m.value > 0
    order by t.sort_order
  loop
    -- A % without its base (gross or net) is never guessed.
    if c.value_kind = 'percentage' and nullif(btrim(coalesce(c.calculation_base, '')), '') is null then raise exception 'calculation_base_missing'; end if;
    v_base := case when upper(c.calculation_base) like 'L%' then v_net else v_gross end;
    v_pbase := case when upper(c.payout_base) like 'L%' then v_net else v_gross end;
    v_received := case when c.value_kind = 'fixed_brl' then round(c.received_value, 2) else round(v_base * c.received_value / 100, 2) end;

    v_o := 0;
    if not v_rule.own_production then
      select * into it from public.commission_group_rule_items i where i.rule_id = v_rule.id and i.component_type_id = c.type_id;
      if it.rule_id is not null and it.distributed_pct > 0 then
        if it.reference_kind = 'company' then
          v_ref := v_received;
        else
          select case when g.value_kind = 'fixed_brl' then round(g.value, 2) else round(v_pbase * g.value / 100, 2) end into v_ref
          from public.commercial_condition_group_values g
          where g.condition_id = v_cond.id and g.component_type_id = c.type_id
            and g.group_id = case when it.reference_kind = 'own' then v_seller.commission_group_id else it.reference_group_id end;
        end if;
        v_o := round(coalesce(v_ref, 0) * it.distributed_pct / 100, 2);
      end if;
    end if;

    v_s := 0; v_m := 0;
    if v_sup is not null then
      v_s := round(case v_rule.supervisor_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.supervisor_pct / 100, 2);
    end if;
    if v_mgr is not null then
      v_m := round(case v_rule.manager_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.manager_pct / 100, 2);
    end if;
    if v_o + v_s + v_m > v_received then raise exception 'payout_exceeds_received'; end if;
    if v_received = 0 then continue; end if;

    v_t := round(v_received * v_cond.tax_pct / 100, 2);
    v_i := round(v_received * v_ir / 100, 2);

    if c.tech_key = 'deferred' and coalesce(p.term, 0) > 0 then
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, x.part, x.mult, x.kind, x.amt
      from (
        with s as (
          select kk.kind, d.standard, d.last
          from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o)) kk(kind, total)
          cross join lateral private.deferred_schedule(kk.total, p.term) d
        )
        select 'deferred_standard' as part, p.term - 1 as mult, s.kind, s.standard as amt from s
        union all select 'deferred_last', 1, s.kind, s.last from s
        union all select 'deferred_standard', p.term - 1, 'company', sum(case when s.kind = 'received' then s.standard else -s.standard end) from s
        union all select 'deferred_last', 1, 'company', sum(case when s.kind = 'received' then s.last else -s.last end) from s
      ) x;
    else
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, 'upfront', 1, x.kind, x.amt
      from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o),
                   ('company', v_received - v_t - v_i - v_m - v_s - v_o)) x(kind, amt);
    end if;
  end loop;
  perform set_config('corban.commission_rpc', 'off', true);
  return v_calc;
end
$function$;

revoke all on function private.contract_commission_core(uuid, uuid) from public, anon, authenticated;

-- Type, change or remove (p_kind 'remove') the commission received for one contract and one component.
-- p_kind: 'pct_liquido' | 'pct_bruto' | 'brl' | 'remove'. p_value: dot decimal text ("2.5", "150.00").
create or replace function public.set_contract_manual_commission(p_proposal uuid, p_component text, p_kind text, p_value text, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  v_type uuid;
  v_value numeric;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_kind text; v_base text;
  x record;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.has_active_organization_role(p.organization_id, array['admin', 'manager'])
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then
    raise exception 'not_authorized';
  end if;
  if p.status in ('rejected', 'cancelled') then raise exception 'contract_closed'; end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;
  select t.id into v_type from public.commission_component_types t where t.tech_key = p_component and t.is_active;
  if v_type is null then raise exception 'invalid_component'; end if;
  if length(v_reason) not between 3 and 500 then raise exception 'reason_required'; end if;

  if p_kind = 'remove' then
    if not exists (select 1 from public.proposal_manual_components m where m.proposal_id = p.id and m.component_type_id = v_type) then
      raise exception 'manual_commission_not_found';
    end if;
    select m.value_kind, m.base into v_kind, v_base from public.proposal_manual_components m
    where m.proposal_id = p.id and m.component_type_id = v_type order by m.created_at desc, m.id desc limit 1;
    v_value := 0;
  else
    if p_kind not in ('pct_liquido', 'pct_bruto', 'brl') then raise exception 'invalid_manual_commission'; end if;
    v_kind := case when p_kind = 'brl' then 'fixed_brl' else 'percentage' end;
    v_base := case p_kind when 'pct_liquido' then 'LÍQUIDO' when 'pct_bruto' then 'BRUTO' end;
    if coalesce(p_value, '') !~ (case when p_kind = 'brl' then '^[0-9]{1,9}(\.[0-9]{1,2})?$' else '^[0-9]{1,3}(\.[0-9]{1,4})?$' end) then
      raise exception 'invalid_amount';
    end if;
    v_value := p_value::numeric;
    if v_value <= 0 or (v_kind = 'percentage' and v_value > 100) then raise exception 'invalid_amount'; end if;
  end if;

  perform set_config('corban.manual_commission_rpc', 'on', true);
  insert into public.proposal_manual_components (organization_id, proposal_id, component_type_id, value_kind, base, value, reason, created_by)
  values (p.organization_id, p.id, v_type, v_kind, v_base, v_value, v_reason, auth.uid());
  perform set_config('corban.manual_commission_rpc', 'off', true);

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'manual_commission',
          jsonb_build_object('component', p_component, 'kind', case when p_kind = 'remove' then 'remove' else v_kind end, 'base', v_base, 'value', v_value::text),
          v_reason, auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);

  -- Recalculate now: a calculated contract follows the new value, and a payout change above the new receipt refuses the
  -- whole change (as update_contract). A contract not calculated yet is tried; a failure stays recorded on it.
  if exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then
    perform private.contract_commission_core(p.id, null);
    for x in select * from private.contract_payable(p.id) loop
      if x.payable > x.received then raise exception 'override_exceeds_received'; end if;
    end loop;
  else
    perform private.try_auto_calculate(p.id);
  end if;
end
$$;

revoke all on function public.set_contract_manual_commission(uuid, text, text, text, text) from public, anon;
grant execute on function public.set_contract_manual_commission(uuid, text, text, text, text) to authenticated;
