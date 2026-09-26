-- Contracts are born calculated (owner decision 26/09/2026, ADR-0040).
--
-- A contract created on a table that has its commission registered gets its commission at once, whoever creates it
-- (a seller included): the calculation is a system action. A portal proposal is calculated when the company approves
-- it (before that it is not in the pipeline). When the calculation cannot run (no table line for the term, seller
-- without group, a % without base...), the contract is still created and the reason is recorded in its history
-- (kind calc_failed) so the screen can say why and offer "Tentar de novo". Manual recalculation stays as before.
-- The calculation body moves to private.contract_commission_core; calculate_contract_commission keeps the caller checks.

alter table public.contract_events drop constraint contract_events_kind_check;
alter table public.contract_events add constraint contract_events_kind_check
  check (kind in ('edit', 'note', 'recalculated', 'payout_override', 'payout_override_cleared', 'calc_failed'));
drop policy contract_events_select on public.contract_events;
create policy contract_events_select on public.contract_events for select to authenticated
  using (exists (select 1 from public.proposals_v2 p where p.id = proposal_id and p.organization_id = contract_events.organization_id
                 and public.is_active_organization_member(p.organization_id) and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by))
         and (kind in ('edit', 'note', 'recalculated', 'calc_failed') or public.has_permission(organization_id, 'financeiro.view')));

create or replace function private.contract_commission_core(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
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
  v_base numeric; v_received numeric; v_ref numeric;
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
  if exists (select 1 from public.payout_entries e where e.proposal_id = p.id and e.kind = 'commission') then raise exception 'commission_already_posted'; end if;

  -- Line of the table: explicit, or the only one of the contract's table version matching the term and amount.
  if p_condition_id is not null then
    select * into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond.id is null then raise exception 'condition_not_found'; end if;
  else
    select count(*) into v_count from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
    if v_count = 0 then raise exception 'condition_not_found'; end if;
    if v_count > 1 then raise exception 'condition_ambiguous'; end if;
    select * into v_cond from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
  end if;

  select coalesce(b.ir_withheld_pct, 0) into v_ir
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

  for c in
    select t.id as type_id, t.tech_key, k.value_kind, k.received_value, k.calculation_base
    from public.commercial_condition_components k join public.commission_component_types t on t.id = k.component_type_id
    where k.condition_id = v_cond.id order by t.sort_order
  loop
    -- A % without its base (gross or net) is never guessed.
    if c.value_kind = 'percentage' and nullif(btrim(coalesce(c.calculation_base, '')), '') is null then raise exception 'calculation_base_missing'; end if;
    v_base := case when upper(c.calculation_base) like 'L%' then v_net else v_gross end;
    v_received := case when c.value_kind = 'fixed_brl' then round(c.received_value, 2) else round(v_base * c.received_value / 100, 2) end;

    v_o := 0;
    if not v_rule.own_production then
      select * into it from public.commission_group_rule_items i where i.rule_id = v_rule.id and i.component_type_id = c.type_id;
      if it.rule_id is not null and it.distributed_pct > 0 then
        if it.reference_kind = 'company' then
          v_ref := v_received;
        else
          select case when g.value_kind = 'fixed_brl' then round(g.value, 2) else round(v_base * g.value / 100, 2) end into v_ref
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
$$;
revoke all on function private.contract_commission_core(uuid, uuid) from public, anon, authenticated;

create or replace function public.calculate_contract_commission(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal_id;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id) then raise exception 'not_authorized'; end if;
  if not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if not (public.has_permission(p.organization_id, 'propostas.edit') or public.has_permission(p.organization_id, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  return private.contract_commission_core(p_proposal_id, p_condition_id);
end
$$;
revoke all on function public.calculate_contract_commission(uuid, uuid) from public, anon;
grant execute on function public.calculate_contract_commission(uuid, uuid) to authenticated;

-- Calculate a contract that has no calculation yet; a failure never blocks the contract, it is recorded instead.
-- A portal proposal still waiting for validation is left alone (it is calculated when approved).
create or replace function private.try_auto_calculate(p_proposal uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.proposals_v2 where id = p_proposal;
  if v_org is null or exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p_proposal and c.status = 'active') then return; end if;
  if exists (select 1 from public.proposal_submissions s where s.proposal_id = p_proposal and s.status <> 'validated') then return; end if;
  begin
    perform private.contract_commission_core(p_proposal, null);
  exception when others then
    perform set_config('corban.contract_rpc', 'on', true);
    insert into public.contract_events (organization_id, proposal_id, kind, detail, actor_user_id)
    values (v_org, p_proposal, 'calc_failed', jsonb_build_object('code', left(sqlerrm, 120)), auth.uid());
    perform set_config('corban.contract_rpc', 'off', true);
  end;
end
$$;
revoke all on function private.try_auto_calculate(uuid) from public, anon, authenticated;

create or replace function private.auto_calculate_new_contract()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform private.try_auto_calculate(new.id);
  return null;
end
$$;
revoke all on function private.auto_calculate_new_contract() from public, anon, authenticated;
-- At commit, when the contract, its pipeline case and (for the portal) its submission all exist.
create constraint trigger proposals_v2_90_auto_calculate after insert on public.proposals_v2
  deferrable initially deferred for each row execute function private.auto_calculate_new_contract();

create or replace function private.auto_calculate_validated_submission()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.status = 'validated' and old.status is distinct from 'validated' then perform private.try_auto_calculate(new.proposal_id); end if;
  return null;
end
$$;
revoke all on function private.auto_calculate_validated_submission() from public, anon, authenticated;
create constraint trigger proposal_submissions_90_auto_calculate after update on public.proposal_submissions
  deferrable initially deferred for each row execute function private.auto_calculate_validated_submission();
