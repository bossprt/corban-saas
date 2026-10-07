-- Amount ranges of the table lines (owner request 07/10/2026, FINTECH CORBAN tables).
--
-- 1. The amount range of a line is matched on the amount of the line's base: a net line (commission on the released
--    amount) compares the released amount; a gross line compares the contract's amount. Banks set FGTS bands on the
--    amount released to the client (owner: "valor mínimo 40 e o máximo 150 ao cliente"). Lines without range are
--    unchanged. Checked before applying: the 13 active calculations on lines with a range (PROSESP) keep their line.
-- 2. The table import reads "Valor Inicial" / "Valor Final" (amount_min / amount_max): the line is found by term AND
--    amount range, so the bands of one table no longer overwrite each other. Both or neither; 0 to 999.999.999,99.
-- 3. A commission line may come without monthly rate or coefficient (bank commission exports have none); the
--    simulation of such a line stays "manual_pending", as it already does without a coefficient.
-- Contract: tests/security/table-amount-ranges-contract.sql

create or replace function private.condition_amount_fits(p_condition_id uuid, p_amount_min numeric, p_amount_max numeric,
                                                          p_requested numeric, p_released numeric)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select p_amount_min is null and p_amount_max is null
      or coalesce((
           select v between coalesce(p_amount_min, 0) and coalesce(p_amount_max, 999999999.99)
           from (select case when exists (select 1 from public.commercial_condition_components c
                                          where c.condition_id = p_condition_id and upper(c.calculation_base) like 'L%')
                             then coalesce(p_released, p_requested)
                             else coalesce(p_requested, p_released) end as v) a), false);
$$;
revoke all on function private.condition_amount_fits(uuid, numeric, numeric, numeric, numeric) from public, anon, authenticated;

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

CREATE OR REPLACE FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  rowj jsonb;
  comp jsonb;
  v_bank public.organization_banks%rowtype;
  v_agreement public.organization_agreements%rowtype;
  v_route public.organization_product_routes%rowtype;
  v_table public.product_tables%rowtype;
  v_version public.product_table_versions%rowtype;
  v_condition public.commercial_conditions%rowtype;
  v_contract public.contract_types%rowtype;
  v_factor_profile public.commercial_factor_profiles%rowtype;
  v_factor_batch public.commercial_factor_batches%rowtype;
  v_bank_name text;
  v_agreement_name text;
  v_table_name text;
  v_external_code text;
  v_contract_name text;
  v_contract_id uuid;
  v_term_min integer;
  v_term_max integer;
  v_amount_min numeric;
  v_amount_max numeric;
  v_coefficient numeric;
  v_rate numeric;
  v_effective_from timestamptz;
  v_effective_until timestamptz;
  v_factor_mode text;
  v_factor_value numeric;
  v_factor_date date;
  v_component_type uuid;
  v_value_kind text;
  v_received numeric;
  v_tax numeric;
  v_origin text;
  v_row_provider uuid;
  v_created_banks integer:=0;
  v_created_agreements integer:=0;
  v_created_tables integer:=0;
  v_created_versions integer:=0;
  v_upserted_conditions integer:=0;
  v_component_count integer:=0;
  v_factor_count integer:=0;
  v_token text:='smart-import:'||replace(gen_random_uuid()::text,'-','');
  v_batch_ids uuid[]:='{}';
begin
  if auth.uid() is null or p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager']) then
    raise exception 'not_authorized';
  end if;
  if p_production_origin not in ('own','third_party') then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='own' and p_provider is not null then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='third_party' then
    if p_provider is null or not exists(select 1 from public.organization_providers x where x.organization_id=p_organization and x.id=p_provider and x.is_active)
    then raise exception 'invalid_provider'; end if;
  end if;
  if p_policy_version is not null then raise exception 'component_policy_removed'; end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>1000 then
    raise exception 'invalid_smart_import_rows';
  end if;

  for rowj in select * from jsonb_array_elements(p_rows) loop
    v_bank_name:=nullif(btrim(rowj->>'bank_name'),'');
    v_agreement_name:=nullif(btrim(rowj->>'agreement_name'),'');
    v_table_name:=nullif(btrim(rowj->>'table_name'),'');
    v_external_code:=nullif(btrim(rowj->>'external_table_code'),'');
    v_contract_name:=nullif(btrim(rowj->>'contract_type_name'),'');
    begin
      v_contract_id:=nullif(rowj->>'contract_type_id','')::uuid;
      v_term_min:=coalesce(nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_term_max:=coalesce(nullif(rowj->>'term_max',''),nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_coefficient:=case when nullif(rowj->>'coefficient','') is null then null else (rowj->>'coefficient')::numeric end;
      v_rate:=case when nullif(rowj->>'rate','') is null then null else (rowj->>'rate')::numeric end;
      v_amount_min:=case when nullif(rowj->>'amount_min','') is null then null else (rowj->>'amount_min')::numeric end;
      v_amount_max:=case when nullif(rowj->>'amount_max','') is null then null else (rowj->>'amount_max')::numeric end;
      v_effective_from:=case when nullif(rowj->>'effective_from','') is null then null else (rowj->>'effective_from')::timestamptz end;
      v_effective_until:=case when nullif(rowj->>'effective_until','') is null then null else (rowj->>'effective_until')::timestamptz end;
      v_factor_mode:=nullif(rowj->>'factor_mode','');
      v_factor_value:=case when nullif(rowj->>'factor_value','') is null then null else (rowj->>'factor_value')::numeric end;
      v_factor_date:=case when nullif(rowj->>'factor_date','') is null then coalesce(v_effective_from::date,current_date) else (rowj->>'factor_date')::date end;
      v_tax:=case when nullif(rowj->>'tax_pct','') is null then null else (rowj->>'tax_pct')::numeric end;
    exception when others then raise exception 'invalid_smart_import_row'; end;

    if v_bank_name is null or length(v_bank_name)>120
       or v_agreement_name is null or length(v_agreement_name)>120
       or v_table_name is null or length(v_table_name)>120
       or v_term_min not between 1 and 600
       or v_term_max not between 1 and 600
       or v_term_min>v_term_max
       or ((v_amount_min is null)<>(v_amount_max is null))
       or (v_amount_min is not null and (v_amount_min<0 or v_amount_max<v_amount_min or v_amount_max>999999999.99))
       or (v_coefficient is not null and v_coefficient<0)
       or (v_rate is not null and v_rate<0)
       or (v_effective_from is not null and v_effective_until is not null and v_effective_until<v_effective_from)
       or (v_tax is not null and (v_tax<0 or v_tax>100))
    then raise exception 'invalid_smart_import_row'; end if;

    -- Contract type can be supplied by id or exact name; tenant-enabled/visible constraints still apply.
    if v_contract_id is not null then
      select * into v_contract from public.contract_types x
      where x.id=v_contract_id and x.is_active and (x.organization_id is null or x.organization_id=p_organization);
    else
      select * into v_contract from public.contract_types x
      where lower(btrim(x.name))=lower(v_contract_name) and x.is_active and (x.organization_id is null or x.organization_id=p_organization)
      order by (x.organization_id=p_organization) desc nulls last limit 1;
    end if;
    if v_contract.id is null then raise exception 'contract_type_not_found'; end if;
    if exists(select 1 from public.organization_contract_type_settings s where s.organization_id=p_organization and s.contract_type_id=v_contract.id and (not s.is_enabled or not s.use_in_commission))
    then raise exception 'contract_type_disabled'; end if;

    -- Origin of the line: the file's "Promotora parceira" column when present (an exported table goes back to its own
    -- origin), otherwise the origin chosen on the import screen.
    if rowj ? 'production_origin' then
      v_origin:=rowj->>'production_origin';
      begin v_row_provider:=nullif(rowj->>'provider_id','')::uuid; exception when others then raise exception 'invalid_smart_import_row'; end;
      if v_origin is null or v_origin not in ('own','third_party') or (v_origin='own' and v_row_provider is not null) then raise exception 'invalid_production_origin'; end if;
      if v_origin='third_party' and (v_row_provider is null or not exists(select 1 from public.organization_providers x where x.organization_id=p_organization and x.id=v_row_provider and x.is_active))
      then raise exception 'invalid_provider'; end if;
    else
      v_origin:=p_production_origin;
      v_row_provider:=p_provider;
    end if;

    -- Exact tenant catalog match first; create only when absent.
    select * into v_bank from public.organization_banks x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_bank_name) limit 1;
    if v_bank.id is null then
      insert into public.organization_banks(organization_id,name) values(p_organization,v_bank_name) returning * into v_bank;
      v_created_banks:=v_created_banks+1;
    elsif not v_bank.is_active then raise exception 'bank_inactive'; end if;

    select * into v_agreement from public.organization_agreements x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_agreement_name) limit 1;
    if v_agreement.id is null then
      insert into public.organization_agreements(organization_id,name) values(p_organization,v_agreement_name) returning * into v_agreement;
      v_created_agreements:=v_created_agreements+1;
    elsif not v_agreement.is_active then raise exception 'agreement_inactive'; end if;

    select * into v_route from public.organization_product_routes x
    where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
      and ((v_row_provider is null and x.org_provider_id is null) or x.org_provider_id=v_row_provider)
      and x.production_origin=v_origin
    limit 1;
    if v_route.id is null then
      insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status)
      values(p_organization,v_bank.id,v_row_provider,v_agreement.id,v_origin,'active') returning * into v_route;
    end if;

    select * into v_table from public.product_tables x
    where x.organization_id=p_organization and x.route_id=v_route.id and lower(btrim(x.name))=lower(v_table_name)
    order by x.created_at desc limit 1;
    if v_table.id is null then
      insert into public.product_tables(organization_id,route_id,code,name,status)
      values(p_organization,v_route.id,'t-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),v_table_name,'active')
      returning * into v_table;
      v_created_tables:=v_created_tables+1;
    elsif v_table.status<>'active' then raise exception 'product_table_inactive'; end if;
    -- The file's "Tipo de formalização" sets the table's (no column = the table keeps what it has; never guessed).
    if rowj ? 'formalization' then
      if coalesce(rowj->>'formalization','') not in ('digital','physical') then raise exception 'invalid_formalization'; end if;
      if v_table.formalization is distinct from rowj->>'formalization' then
        perform set_config('corban.catalog_rpc','on',true);
        update public.product_tables set formalization=rowj->>'formalization' where id=v_table.id returning * into v_table;
        perform set_config('corban.catalog_rpc','off',true);
      end if;
    end if;

    select * into v_version from public.product_table_versions x
    where x.organization_id=p_organization and x.product_table_id=v_table.id and x.status='draft'
    order by x.version desc limit 1;
    if v_version.id is null then
      insert into public.product_table_versions(organization_id,product_table_id,version,status,effective_from,effective_until,metadata)
      select p_organization,v_table.id,coalesce(max(x.version),0)+1,'draft',v_effective_from,v_effective_until,
        jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      from public.product_table_versions x where x.product_table_id=v_table.id
      returning * into v_version;
      v_created_versions:=v_created_versions+1;
    else
      update public.product_table_versions
      set effective_from=coalesce(v_effective_from,effective_from),
          effective_until=coalesce(v_effective_until,effective_until),
          metadata=metadata||jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      where id=v_version.id returning * into v_version;
    end if;

    select * into v_condition from public.commercial_conditions x
    where x.organization_id=p_organization and x.product_table_version_id=v_version.id and x.contract_type_id=v_contract.id
      and x.term_min=v_term_min and x.term_max=v_term_max
      and x.amount_min is not distinct from v_amount_min and x.amount_max is not distinct from v_amount_max
    limit 1;

    perform set_config('corban.condition_rpc','on',true);
    if v_condition.id is null then
      insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,term_min,term_max,amount_min,amount_max,coefficient,rate,tax_pct,created_by)
      values(p_organization,v_version.id,v_contract.id,v_term_min,v_term_min,v_term_max,v_amount_min,v_amount_max,v_coefficient,v_rate,trim_scale(coalesce(v_tax,0)),auth.uid())
      returning * into v_condition;
    else
      update public.commercial_conditions
      set term=v_term_min,term_min=v_term_min,term_max=v_term_max,coefficient=v_coefficient,rate=v_rate,
          tax_pct=case when rowj ? 'tax_pct' then trim_scale(coalesce(v_tax,0)) else tax_pct end,updated_at=now()
      where id=v_condition.id returning * into v_condition;
    end if;
    perform set_config('corban.condition_rpc','off',true);
    v_upserted_conditions:=v_upserted_conditions+1;

    -- Replace all received components for the condition only after the row has been fully validated.
    perform public.replace_commercial_condition_components(
      v_condition.id,
      coalesce(rowj->'components','[]'::jsonb)
    );
    v_component_count:=v_component_count+jsonb_array_length(coalesce(rowj->'components','[]'::jsonb));
    -- Part B (ADR-0036): the value of each seller group for each commission type, when the file brings group columns.
    if rowj ? 'group_values' then
      perform public.replace_condition_group_values(v_condition.id, rowj->'group_values');
    end if;


    -- Factor is its own versioned domain. When present, import a revision for the same commercial scope.
    if v_factor_value is not null then
      if v_factor_value<=0 or v_factor_mode not in ('daily','fixed') then raise exception 'invalid_factor'; end if;
      select * into v_factor_profile from public.commercial_factor_profiles x
      where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
        and x.product_table_id=v_table.id and x.contract_type_id=v_contract.id and x.factor_mode=v_factor_mode
      limit 1;
      if v_factor_profile.id is null then
        insert into public.commercial_factor_profiles(
          organization_id,name,org_bank_id,org_agreement_id,product_table_id,contract_type_id,factor_mode,created_by
        ) values(
          p_organization,left(v_bank.name||' · '||v_agreement.name||' · '||v_table.name||' · '||v_contract.name,120),
          v_bank.id,v_agreement.id,v_table.id,v_contract.id,v_factor_mode,auth.uid()
        ) returning * into v_factor_profile;
      end if;

      select * into v_factor_batch from public.commercial_factor_batches x
      where x.organization_id=p_organization and x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        and x.status='draft' and x.source_note=v_token
      limit 1;
      if v_factor_batch.id is null then
        insert into public.commercial_factor_batches(organization_id,profile_id,effective_date,revision,status,source_kind,source_note,created_by)
        select p_organization,v_factor_profile.id,v_factor_date,coalesce(max(x.revision),0)+1,'draft','file',v_token,auth.uid()
        from public.commercial_factor_batches x where x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        returning * into v_factor_batch;
        v_batch_ids:=v_batch_ids||v_factor_batch.id;
      end if;

      insert into public.commercial_factor_entries(organization_id,batch_id,term_min,term_max,factor_value,metadata)
      values(p_organization,v_factor_batch.id,v_term_min,v_term_max,v_factor_value,jsonb_build_object('smart_import',true))
      on conflict(batch_id,term_min,term_max) do update set factor_value=excluded.factor_value,metadata=excluded.metadata;
      v_factor_count:=v_factor_count+1;
    end if;
  end loop;

  if array_length(v_batch_ids,1) is not null then
    foreach v_contract_id in array v_batch_ids loop
      perform public.publish_commercial_factor_batch(v_contract_id);
    end loop;
  end if;

  return jsonb_build_object(
    'created_banks',v_created_banks,
    'created_agreements',v_created_agreements,
    'created_tables',v_created_tables,
    'created_versions',v_created_versions,
    'upserted_conditions',v_upserted_conditions,
    'components',v_component_count,
    'factors',v_factor_count
  );
exception when others then
  perform set_config('corban.condition_rpc','off',true);
  perform set_config('corban.smart_import_rpc','off',true);
  raise;
end $function$;
