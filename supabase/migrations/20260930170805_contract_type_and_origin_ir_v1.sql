-- Bank, contract type and table (owner request 29/09/2026, ADR-0049).
--
-- 1. A contract records its contract type (Novo, Refinanciamento, Portabilidade...). The commission takes the table line of
--    that type, so a table with Novo 6-8 and Refin 6-10 months no longer stops a contract of 8 months ("condition_ambiguous",
--    contract 13952). A recalculation keeps the line used before while it still fits. Editing a contract that has no
--    commission yet now tries to calculate it (a failure is recorded, the edit stays).
-- 2. The type comes from the proposal forms, the broker portal and the simulation (which already asked for it). The
--    former signatures of create_direct_proposal and submit_broker_proposal still work, without a type.
-- 3. IR withheld per origin (route): a field the owner fills, default empty. Empty means the bank's IR for own production
--    and 0 through a promoter (the promoter pays the commission already free). No percentage is decided by the system.

alter table public.proposals_v2 add column contract_type_id uuid references public.contract_types(id) on delete restrict;
create index proposals_v2_contract_type_idx on public.proposals_v2 (contract_type_id);
alter table public.organization_product_routes add column ir_withheld_pct numeric(9,6)
  check (ir_withheld_pct is null or (ir_withheld_pct >= 0 and ir_withheld_pct <= 100));

-- The type must be one this table version has lines for (the company's own type or a global one).
create or replace function private.check_contract_type_in_version(p_org uuid, p_version uuid, p_type uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if p_type is null then return; end if;
  if not exists (select 1 from public.contract_types ct where ct.id = p_type and (ct.organization_id is null or ct.organization_id = p_org)) then
    raise exception 'contract_type_not_found';
  end if;
  if not exists (select 1 from public.commercial_conditions k where k.organization_id = p_org and k.product_table_version_id = p_version and k.contract_type_id = p_type) then
    raise exception 'contract_type_not_in_table';
  end if;
end
$$;
revoke all on function private.check_contract_type_in_version(uuid, uuid, uuid) from public, anon, authenticated;

-- IR withheld for one origin: a bank through a promoter (all routes of that pair) or the bank's own production (provider
-- empty). Empty clears it (back to the default above).
create or replace function public.set_origin_ir_withheld(p_bank uuid, p_provider uuid, p_pct text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  b public.organization_banks%rowtype;
  v numeric;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into b from public.organization_banks where id = p_bank;
  if b.id is null or not public.has_active_organization_role(b.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if coalesce(p_pct, '') = '' then v := null;
  elsif p_pct !~ '^[0-9]{1,3}(\.[0-9]{1,6})?$' then raise exception 'invalid_ir_withheld';
  else v := trim_scale(p_pct::numeric); end if;
  if v > 100 then raise exception 'invalid_ir_withheld'; end if;
  if not exists (select 1 from public.organization_product_routes r where r.organization_id = b.organization_id and r.org_bank_id = b.id
                 and r.org_provider_id is not distinct from p_provider) then
    raise exception 'origin_not_found';
  end if;
  update public.organization_product_routes r set ir_withheld_pct = v
   where r.organization_id = b.organization_id and r.org_bank_id = b.id and r.org_provider_id is not distinct from p_provider;
end
$$;
revoke all on function public.set_origin_ir_withheld(uuid, uuid, text) from public, anon;
grant execute on function public.set_origin_ir_withheld(uuid, uuid, text) to authenticated;

-- What the proposal forms offer (Banco -> Tipo -> Tabela): the vigência in force now of each active table (plus
-- p_keep, a contract's own older one), with bank, promoter and the contract types of its lines. No rate, no commission:
-- brokers and sellers may call it; the lines themselves stay visible only to who may see rates.
create or replace function public.proposal_catalog(p_org uuid, p_keep uuid default null)
returns table (version_id uuid, version integer, table_name text, bank_id uuid, bank_name text, provider_id uuid, provider_name text, contract_type_id uuid, kept boolean)
language sql
stable
security definer
set search_path to ''
as $$
  with newest as (
    select distinct on (v.product_table_id) v.id, v.version, v.product_table_id
    from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id and t.status = 'active'
    where v.organization_id = p_org and v.status = 'published'
      -- in force now (same rule as the simulation): started, and not ended
      and coalesce(v.effective_from, v.published_at, v.created_at) <= now() and (v.effective_until is null or now() < v.effective_until)
    order by v.product_table_id, v.version desc
  ), chosen as (
    select id, version, product_table_id, false as kept from newest
    union all
    select v.id, v.version, v.product_table_id, true from public.product_table_versions v
    where p_keep is not null and v.id = p_keep and v.organization_id = p_org and not exists (select 1 from newest n where n.id = p_keep)
  )
  select c.id, c.version, t.name, b.id, b.name, pr.id, pr.name, k.contract_type_id, c.kept
  from chosen c
  join public.product_tables t on t.id = c.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id
  left join public.organization_providers pr on pr.id = r.org_provider_id
  left join lateral (select distinct k.contract_type_id from public.commercial_conditions k where k.product_table_version_id = c.id) k on true
  where auth.uid() is not null and public.is_active_organization_member(p_org)
$$;
revoke all on function public.proposal_catalog(uuid, uuid) from public, anon;
grant execute on function public.proposal_catalog(uuid, uuid) to authenticated;

-- Commission: line by contract type; keep the previous line on recalculation; IR by origin.
CREATE OR REPLACE FUNCTION private.contract_commission_core(p_proposal_id uuid, p_condition_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- Line of the table: explicit, or the only one of the contract's table version matching the term and amount.
  if p_condition_id is not null then
    select * into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond.id is null then raise exception 'condition_not_found'; end if;
  else
    -- A recalculation keeps the line used before while it still fits the contract (type, term, amount).
    select k.* into v_cond from public.proposal_commission_calcs x join public.commercial_conditions k on k.id = x.condition_id
    where x.proposal_id = p.id and x.status = 'active' and k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
    if v_cond.id is null then
      -- Else the only line of the table version for the contract's type (when set), term and amount.
      select count(*) into v_count from public.commercial_conditions k
      where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
        and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
        and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
        and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
        and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
      if v_count = 0 then raise exception 'condition_not_found'; end if;
      if v_count > 1 then raise exception 'condition_ambiguous'; end if;
      select * into v_cond from public.commercial_conditions k
      where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
        and (p.contract_type_id is null or k.contract_type_id = p.contract_type_id)
        and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
        and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
        and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
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
$function$;

-- Direct proposal with the contract type.
CREATE OR REPLACE FUNCTION public.create_direct_proposal(p_org uuid, p_customer_id uuid, p_table_version_id uuid, p_seller_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_stage text, p_contract_type_id uuid)
 RETURNS TABLE(proposal_id uuid, duplicate boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_client public.clients%rowtype;
  v_bank_key text;
  v_bank_name text;
  v_table_name text;
  v_ade text := nullif(btrim(coalesce(p_ade, '')), '');
  v_existing uuid;
  v_id uuid;
  v_stage uuid;
  v_sla integer;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  if not public.has_permission(p_org, 'propostas.create') then raise exception 'not_authorized'; end if;
  if p_stage not in ('digitization_queue','submitted') then raise exception 'invalid_stage'; end if;
  if p_stage = 'submitted' and v_ade is null then raise exception 'ade_required'; end if;
  if v_ade is not null and (length(v_ade) > 60 or v_ade !~ '^[A-Za-z0-9./-]+$') then raise exception 'invalid_ade'; end if;
  if coalesce(p_requested_amount, 0) < 0 or coalesce(p_released_amount, 0) < 0 or coalesce(p_installment_amount, 0) < 0 then raise exception 'invalid_amount'; end if;
  if p_released_amount is null and p_requested_amount is null then raise exception 'amount_required'; end if;
  if p_term is not null and (p_term < 1 or p_term > 420) then raise exception 'invalid_term'; end if;

  select * into v_client from public.clients c where c.organization_id = p_org and c.id = p_customer_id and c.deleted_at is null;
  if not found or not private.can_see_client_row(p_org, v_client.id, v_client.owner_user_id) then raise exception 'client_not_found'; end if;
  if p_seller_id is not null and not exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and s.id = p_seller_id and s.is_active) then
    raise exception 'seller_not_found';
  end if;

  select coalesce(ob.tech_key, ob.name), ob.name, t.name into v_bank_key, v_bank_name, v_table_name
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id and t.organization_id = v.organization_id
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = t.organization_id
  left join public.organization_banks ob on ob.id = r.org_bank_id and ob.organization_id = r.organization_id
  where v.organization_id = p_org and v.id = p_table_version_id and v.status = 'published';
  if v_bank_key is null then raise exception 'table_not_found'; end if;
  perform private.check_contract_type_in_version(p_org, p_table_version_id, p_contract_type_id);

  -- Same bank + ADE: the proposal already exists.
  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    select e.proposal_id into v_existing from public.proposal_external_identities e
    where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade;
    if v_existing is not null then return query select v_existing, true; return; end if;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by, contract_type_id)
  values (p_org, p_customer_id, null, p_table_version_id, case when p_stage = 'submitted' then 'submitted' else 'digitization' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_client.full_name, 'cpf', v_client.cpf),
          jsonb_build_object('origin', 'direct', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          p_seller_id, auth.uid(), p_contract_type_id)
  returning id into v_id;

  if v_ade is not null then
    insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source)
    values (p_org, v_id, v_bank_key, v_ade, 'manual');
  end if;

  select s.id, s.sla_minutes into v_stage, v_sla from public.operational_stages s
  where s.organization_id = p_org and s.canonical_state = p_stage and s.is_active order by s.sort_order limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc', 'on', true);
  insert into public.operational_cases (organization_id, proposal_id, current_stage_id, canonical_state, owner_user_id, entered_stage_at, due_at)
  values (p_org, v_id, v_stage, p_stage, auth.uid(), now(), case when v_sla is null then null else now() + make_interval(mins => v_sla) end);
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return query select v_id, false;
end
$function$;

CREATE OR REPLACE FUNCTION public.create_direct_proposal(p_org uuid, p_customer_id uuid, p_table_version_id uuid, p_seller_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_stage text)
 RETURNS TABLE(proposal_id uuid, duplicate boolean)
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  -- Former signature (no contract type): same function, type left empty. Runs as the caller; the full function checks.
  select * from public.create_direct_proposal(p_org, p_customer_id, p_table_version_id, p_seller_id, p_requested_amount, p_released_amount, p_installment_amount, p_term, p_ade, p_stage, null::uuid)
$function$;

-- Broker portal proposal with the contract type.
CREATE OR REPLACE FUNCTION public.submit_broker_proposal(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_table_version_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_contract_type_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_seller uuid;
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := private.normalize_phone(p_phone);
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_ade text := nullif(btrim(coalesce(p_ade, '')), '');
  v_client uuid;
  v_bank_key text; v_bank_name text; v_table_name text;
  v_id uuid;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) or not public.has_permission(p_org, 'propostas.create') then
    raise exception 'not_authorized';
  end if;
  select s.id into v_seller from public.commercial_sellers s where s.organization_id = p_org and s.user_id = auth.uid() and s.is_active;
  if v_seller is null then raise exception 'seller_profile_required'; end if;
  if not private.is_valid_cpf(v_cpf) then raise exception 'invalid_cpf'; end if;
  if length(v_name) < 3 or length(v_name) > 160 then raise exception 'full_name_required'; end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid_email'; end if;
  if v_ade is not null and (length(v_ade) > 60 or v_ade !~ '^[A-Za-z0-9./-]+$') then raise exception 'invalid_ade'; end if;
  if coalesce(p_requested_amount, 0) < 0 or coalesce(p_released_amount, 0) < 0 or coalesce(p_installment_amount, 0) < 0 then raise exception 'invalid_amount'; end if;
  if p_released_amount is null and p_requested_amount is null then raise exception 'amount_required'; end if;
  if p_term is not null and (p_term < 1 or p_term > 420) then raise exception 'invalid_term'; end if;

  select coalesce(ob.tech_key, ob.name), ob.name, t.name into v_bank_key, v_bank_name, v_table_name
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id and t.organization_id = v.organization_id
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = t.organization_id
  left join public.organization_banks ob on ob.id = r.org_bank_id and ob.organization_id = r.organization_id
  where v.organization_id = p_org and v.id = p_table_version_id and v.status = 'published';
  if v_bank_key is null then raise exception 'table_not_found'; end if;
  perform private.check_contract_type_in_version(p_org, p_table_version_id, p_contract_type_id);

  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    if exists (select 1 from public.proposal_external_identities e
               where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade) then
      raise exception 'proposal_already_exists';
    end if;
  end if;

  -- An existing client is linked as is (nothing of it is changed or returned); a new one is created for the broker.
  perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || v_cpf));
  select c.id into v_client from public.clients c where c.organization_id = p_org and c.cpf = v_cpf and c.deleted_at is null;
  if v_client is null then
    select u.client_id into v_client from private.upsert_client_core(p_org, v_cpf, v_name, v_phone, v_email, 'portal', auth.uid()) u;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by, contract_type_id)
  values (p_org, v_client, null, p_table_version_id, case when v_ade is null then 'digitization' else 'submitted' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_name, 'cpf', v_cpf, 'phone', v_phone, 'email', v_email),
          jsonb_build_object('origin', 'portal', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          v_seller, auth.uid(), p_contract_type_id)
  returning id into v_id;
  if v_ade is not null then
    insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source)
    values (p_org, v_id, v_bank_key, v_ade, 'manual');
  end if;
  perform set_config('corban.proposal_rpc', 'off', true);

  perform set_config('corban.submission_rpc', 'on', true);
  insert into public.proposal_submissions (proposal_id, organization_id, seller_id, submitted_by, status)
  values (v_id, p_org, v_seller, auth.uid(), 'pending');
  perform set_config('corban.submission_rpc', 'off', true);
  return v_id;
end
$function$;

CREATE OR REPLACE FUNCTION public.submit_broker_proposal(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_table_version_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  -- Former signature (no contract type): same function, type left empty. Runs as the caller; the full function checks.
  select public.submit_broker_proposal(p_org, p_cpf, p_full_name, p_phone, p_email, p_table_version_id, p_requested_amount, p_released_amount, p_installment_amount, p_term, p_ade, null::uuid)
$function$;

-- Proposal from a simulation keeps the simulation's contract type.
CREATE OR REPLACE FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_org uuid;
  v_sim public.simulations%rowtype;
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_table public.product_tables%rowtype;
  v_proposal_id uuid;
  v_pricing_at timestamptz;
begin
  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id
    and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status<>'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;

  v_org:=v_sim.organization_id;
  v_pricing_at:=coalesce(
    nullif(v_sim.input_snapshot->>'pricing_effective_at','')::timestamptz,
    v_sim.created_at
  );

  select c.* into v_customer
  from public.clients c
  where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;

  -- The version is validated against the instant when the simulation was created,
  -- never against today's pricing.
  select v.* into v_version
  from public.product_table_versions v
  where v.organization_id=v_org
    and v.id=v_sim.product_table_version_id
    and v.status in ('published','superseded')
    and coalesce(v.effective_from,v.published_at,v.created_at)<=v_pricing_at
    and (v.effective_until is null or v_pricing_at<v.effective_until);

  if v_version.id is null then raise exception 'simulation_pricing_version_not_available'; end if;

  select pt.* into v_table
  from public.product_tables pt
  where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;

  perform set_config('corban.proposal_rpc','on',true);
  insert into public.proposals_v2(
    organization_id,customer_id,simulation_id,product_table_version_id,status,
    requested_amount,released_amount,installment_amount,term,rate,coefficient,
    customer_snapshot,commercial_snapshot,attribution_snapshot,created_by,contract_type_id
  ) values(
    v_org,v_customer.id,v_sim.id,v_version.id,'draft',
    v_sim.requested_amount,v_sim.released_amount,v_sim.installment_amount,
    v_sim.term,v_sim.rate,v_sim.coefficient,
    jsonb_build_object(
      'full_name',v_customer.full_name,'cpf',v_customer.cpf,
      'phone',v_customer.phone,'email',v_customer.email
    ),
    jsonb_build_object(
      'pricing_effective_at',v_pricing_at,
      'product_table',jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version',jsonb_build_object(
        'id',v_version.id,'version',v_version.version,
        'effective_from',v_version.effective_from,'effective_until',v_version.effective_until,
        'rate',v_version.rate,'coefficient',v_version.coefficient
      )
    ),
    jsonb_build_object('original_source',v_customer.original_source),
    auth.uid(),
    -- The contract type chosen in the simulation (ADR-0049), when the simulation recorded one.
    (select ct.id from public.contract_types ct where ct.id = nullif(v_sim.input_snapshot->>'contract_type_id','')::uuid
       and (ct.organization_id is null or ct.organization_id = v_org))
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc','off',true);

  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations
  set status='selected',updated_at=now()
  where organization_id=v_org and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);

  return v_proposal_id;
exception when others then
  perform set_config('corban.proposal_rpc','off',true);
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$function$;

-- Contract edit: the contract type is editable and recorded; an uncalculated contract tries to calculate.
CREATE OR REPLACE FUNCTION public.update_contract(p_proposal uuid, p_data jsonb, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p public.proposals_v2%rowtype;
  n public.proposals_v2%rowtype;
  v_changes jsonb := '{}'::jsonb;
  v_bank text; v_table text;
  x record;
  function_money constant text := '^[0-9]{1,9}(\.[0-9]{1,2})?$';
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
     or not (public.has_permission(p.organization_id, 'propostas.edit') or public.has_permission(p.organization_id, 'financeiro.edit')) then
    raise exception 'not_authorized';
  end if;
  if p.status in ('rejected', 'cancelled') then raise exception 'contract_closed'; end if;
  if p.status = 'paid' and not public.has_active_organization_role(p.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if p.status = 'paid' and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if p_reason is not null and length(p_reason) > 2000 then raise exception 'reason_required'; end if;
  -- Once the seller was paid only the formalization can still be corrected: it no longer moves money.
  if private.contract_payout_received(p.id)
     and (case when jsonb_typeof(p_data) = 'object' then exists (select 1 from jsonb_object_keys(p_data) k where k <> 'formalization') else true end) then
    raise exception 'contract_payout_received';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'invalid_contract_data'; end if;

  n := p;
  begin
    if p_data ? 'table_version_id' then n.product_table_version_id := (p_data->>'table_version_id')::uuid; end if;
    if p_data ? 'seller_id' then n.seller_id := nullif(p_data->>'seller_id', '')::uuid; end if;
    if p_data ? 'term' then n.term := nullif(p_data->>'term', '')::integer; end if;
    if p_data ? 'paid_to_client_on' then n.paid_to_client_on := nullif(p_data->>'paid_to_client_on', '')::date; end if;
    if p_data ? 'formalization' then n.formalization := p_data->>'formalization'; end if;
    if p_data ? 'contract_type_id' then n.contract_type_id := nullif(p_data->>'contract_type_id', '')::uuid; end if;
  exception when others then raise exception 'invalid_contract_data'; end;
  if p_data ? 'requested_amount' then
    if coalesce(p_data->>'requested_amount', '') not in ('') and p_data->>'requested_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.requested_amount := nullif(p_data->>'requested_amount', '')::numeric;
  end if;
  if p_data ? 'released_amount' then
    if coalesce(p_data->>'released_amount', '') not in ('') and p_data->>'released_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.released_amount := nullif(p_data->>'released_amount', '')::numeric;
  end if;
  if p_data ? 'installment_amount' then
    if coalesce(p_data->>'installment_amount', '') not in ('') and p_data->>'installment_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.installment_amount := nullif(p_data->>'installment_amount', '')::numeric;
  end if;
  if n.requested_amount is null and n.released_amount is null then raise exception 'invalid_amount'; end if;
  if n.term is not null and (n.term < 1 or n.term > 420) then raise exception 'invalid_term'; end if;
  if n.formalization not in ('digital', 'physical') then raise exception 'invalid_formalization'; end if;
  if n.paid_to_client_on is distinct from p.paid_to_client_on and (p.status <> 'paid' or n.paid_to_client_on is null or n.paid_to_client_on > current_date) then
    raise exception 'invalid_paid_on';
  end if;
  if n.seller_id is not null and not exists (select 1 from public.commercial_sellers s where s.organization_id = p.organization_id and s.id = n.seller_id and s.is_active) then
    raise exception 'seller_not_found';
  end if;

  perform private.check_contract_type_in_version(p.organization_id, n.product_table_version_id, n.contract_type_id);
  if n.product_table_version_id is distinct from p.product_table_version_id then
    select b.name, t.name into v_bank, v_table
    from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
    join public.organization_product_routes r on r.id = t.route_id join public.organization_banks b on b.id = r.org_bank_id
    where v.id = n.product_table_version_id and v.organization_id = p.organization_id and v.status = 'published';
    if v_table is null then raise exception 'proposal_requires_published_product_table_version'; end if;
    n.commercial_snapshot := coalesce(p.commercial_snapshot, '{}'::jsonb)
      || jsonb_build_object('bank', v_bank, 'table', v_table, 'table_version_id', n.product_table_version_id);
    v_changes := v_changes || jsonb_build_object('table_version_id', jsonb_build_object('from', p.product_table_version_id, 'to', n.product_table_version_id,
                   'from_label', coalesce(p.commercial_snapshot->>'table', ''), 'to_label', v_table));
  end if;
  if n.seller_id is distinct from p.seller_id then
    v_changes := v_changes || jsonb_build_object('seller_id', jsonb_build_object('from', p.seller_id, 'to', n.seller_id,
                   'from_label', (select name from public.commercial_sellers where id = p.seller_id), 'to_label', (select name from public.commercial_sellers where id = n.seller_id)));
  end if;
  if n.requested_amount is distinct from p.requested_amount then v_changes := v_changes || jsonb_build_object('requested_amount', jsonb_build_object('from', p.requested_amount, 'to', n.requested_amount)); end if;
  if n.released_amount is distinct from p.released_amount then v_changes := v_changes || jsonb_build_object('released_amount', jsonb_build_object('from', p.released_amount, 'to', n.released_amount)); end if;
  if n.installment_amount is distinct from p.installment_amount then v_changes := v_changes || jsonb_build_object('installment_amount', jsonb_build_object('from', p.installment_amount, 'to', n.installment_amount)); end if;
  if n.contract_type_id is distinct from p.contract_type_id then
    v_changes := v_changes || jsonb_build_object('contract_type_id', jsonb_build_object('from', p.contract_type_id, 'to', n.contract_type_id,
                   'from_label', (select name from public.contract_types where id = p.contract_type_id), 'to_label', (select name from public.contract_types where id = n.contract_type_id)));
  end if;
  if n.term is distinct from p.term then v_changes := v_changes || jsonb_build_object('term', jsonb_build_object('from', p.term, 'to', n.term)); end if;
  if n.formalization is distinct from p.formalization then v_changes := v_changes || jsonb_build_object('formalization', jsonb_build_object('from', p.formalization, 'to', n.formalization)); end if;
  if n.paid_to_client_on is distinct from p.paid_to_client_on then v_changes := v_changes || jsonb_build_object('paid_to_client_on', jsonb_build_object('from', p.paid_to_client_on, 'to', n.paid_to_client_on)); end if;
  if v_changes = '{}'::jsonb then return; end if;

  perform set_config('corban.contract_edit_rpc', 'on', true);
  update public.proposals_v2
  set product_table_version_id = n.product_table_version_id, seller_id = n.seller_id, requested_amount = n.requested_amount,
      released_amount = n.released_amount, installment_amount = n.installment_amount, term = n.term,
      commercial_snapshot = n.commercial_snapshot, formalization = n.formalization, paid_to_client_on = n.paid_to_client_on,
      contract_type_id = n.contract_type_id, updated_at = now()
  where id = p.id;
  perform set_config('corban.contract_edit_rpc', 'off', true);

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'edit', v_changes, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);

  -- A calculated contract follows its new data at once; if the calculation cannot (no line for the new term, a payout
  -- change above the new receipt...), the whole edit is refused.
  -- Formalization and the paid date do not change the commission: no recalculation for them.
  if (v_changes - 'formalization' - 'paid_to_client_on') <> '{}'::jsonb
     and exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then
    perform public.calculate_contract_commission(p.id);
    for x in select * from private.contract_payable(p.id) loop
      if x.payable > x.received then raise exception 'override_exceeds_received'; end if;
    end loop;
  elsif (v_changes - 'formalization' - 'paid_to_client_on') <> '{}'::jsonb then
    -- Not calculated yet (e.g. the type was missing): try now; a failure is recorded on the contract, the edit stays.
    perform private.try_auto_calculate(p.id);
  end if;
end
$function$;

-- Guard: the contract type changes only through the governed edit.
CREATE OR REPLACE FUNCTION public.guard_proposal_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_edit boolean := coalesce(current_setting('corban.contract_edit_rpc', true) = 'on', false);  -- never null: a null here would open the guard
begin
  if current_user in ('authenticated','anon','service_role')
     and current_setting('corban.proposal_rpc', true) is distinct from 'on'
     and current_setting('corban.paid_evidence_rpc', true) is distinct from 'on'
     and current_setting('corban.proposal_seller_rpc', true) is distinct from 'on'
     and not v_edit then
    raise exception 'proposal_write_requires_governed_rpc';
  end if;

  if tg_op = 'UPDATE' and new.seller_id is distinct from old.seller_id and not v_edit then
    if current_setting('corban.proposal_seller_rpc', true) is distinct from 'on' then raise exception 'proposal_seller_change_requires_governed_rpc'; end if;
    if old.status <> 'draft' then raise exception 'proposal_seller_is_frozen'; end if;
  end if;

  if tg_op = 'UPDATE' and (
     new.id is distinct from old.id
     or new.organization_id is distinct from old.organization_id
     or new.customer_id is distinct from old.customer_id
     or new.simulation_id is distinct from old.simulation_id
     or (new.product_table_version_id is distinct from old.product_table_version_id and not v_edit)
     or (new.contract_type_id is distinct from old.contract_type_id and not v_edit)
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at) then
    raise exception 'proposal_identity_is_immutable';
  end if;
  return new;
end
$function$;

revoke all on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, integer, text, text, uuid) from public, anon;
grant execute on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, integer, text, text, uuid) to authenticated;
revoke all on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text, uuid) from public, anon;
grant execute on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text, uuid) to authenticated;
