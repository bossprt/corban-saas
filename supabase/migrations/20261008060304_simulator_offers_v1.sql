-- Simulator by factor, comparing every table of an agreement (owner request 08/10/2026).
--
-- Owner rules: installment = amount x factor; amount = installment / factor. The simulation starts from the agreement
-- (convênio), the contract type and the term, by amount OR by installment, and shows only the tables that have a factor:
-- the factor published for that bank/agreement/table/type and term (daily: the factor of the simulation date; fixed: the
-- last one published), or, failing that, the coefficient written on the table line. Refin and portability take the
-- outstanding balance (saldo devedor): change (troco) = contract amount - balance.
-- Money: exact numeric. By amount the installment is rounded to the cent; by installment the amount is cut down to the
-- cent so the installment never goes over what the client can pay.
-- 1. private.offer_for(...)          one table version + condition -> the offer (or null when no factor / out of range)
-- 2. public.simulation_offers(...)   every table of the agreement, best first
-- 3. public.save_simulation_offer()  the chosen offer, recalculated on the server, saved as a simulation of the client
--                                    (security definer: simulations are written only through governed functions);
--                                    create_proposal_from_simulation then turns it into a proposal as before.
-- Contract: tests/security/simulator-offers-contract.sql

create or replace function private.offer_for(p_version uuid, p_condition uuid, p_agreement uuid, p_contract_type uuid, p_term integer,
                                             p_mode text, p_value numeric, p_outstanding numeric, p_on date)
returns jsonb language plpgsql stable set search_path to '' as $$
declare v record; k public.commercial_conditions%rowtype; f record; v_factor numeric; v_source text; v_factor_date date;
        v_amount numeric; v_installment numeric; v_change numeric;
begin
  select pv.id as version_id, t.id as table_id, t.name as table_name, r.org_bank_id, r.org_agreement_id, r.org_provider_id,
         b.name as bank_name, pr.name as provider_name
  into v
  from public.product_table_versions pv
  join public.product_tables t on t.id = pv.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id
  left join public.organization_providers pr on pr.id = r.org_provider_id
  where pv.id = p_version;
  if v.version_id is null then return null; end if;
  select * into k from public.commercial_conditions where id = p_condition and product_table_version_id = p_version;
  if k.id is null then return null; end if;

  select * into f from public.resolve_commercial_factor(v.org_bank_id, p_agreement, v.table_id, p_contract_type, p_term, p_on);
  if f.factor_value is not null and f.factor_value > 0 then
    v_factor := f.factor_value; v_source := f.factor_mode; v_factor_date := f.effective_date;
  elsif k.coefficient is not null and k.coefficient > 0 then
    v_factor := k.coefficient; v_source := 'table';
  else
    return null;  -- no factor: the table is not offered
  end if;

  if p_mode = 'amount' then
    v_amount := round(p_value, 2);
    v_installment := round(v_amount * v_factor, 2);
  else
    v_installment := round(p_value, 2);
    v_amount := trunc(v_installment / v_factor, 2);
  end if;
  if k.amount_min is not null and (v_amount < k.amount_min or v_amount > k.amount_max) then return null; end if;
  v_change := case when p_outstanding is null then null else v_amount - round(p_outstanding, 2) end;

  return jsonb_build_object(
    'table_version_id', v.version_id, 'condition_id', k.id, 'table_name', v.table_name,
    'bank', v.bank_name, 'provider', v.provider_name,
    'factor', v_factor, 'factor_source', v_source, 'factor_date', v_factor_date, 'rate', k.rate,
    'term', p_term, 'amount', v_amount, 'installment', v_installment,
    'outstanding', round(p_outstanding, 2), 'change', v_change);
end
$$;

create or replace function public.simulation_offers(p_org uuid, p_agreement uuid, p_contract_type uuid, p_term integer, p_mode text,
                                                    p_value numeric, p_outstanding numeric default null, p_on date default null)
returns jsonb language plpgsql stable set search_path to '' as $$
declare v_on date := coalesce(p_on, (now() at time zone 'America/Sao_Paulo')::date); x record; o jsonb; v_out jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or p_org is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  if p_mode not in ('amount', 'installment') then raise exception 'invalid_mode'; end if;
  if p_value is null or p_value <= 0 or p_value > 999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term < 1 or p_term > 600 then raise exception 'invalid_term'; end if;
  if p_outstanding is not null and (p_outstanding < 0 or p_outstanding > 999999999) then raise exception 'invalid_outstanding'; end if;
  for x in
    select distinct on (pv.id) pv.id as version_id, k.id as condition_id
    from public.product_table_versions pv
    join public.product_tables t on t.id = pv.product_table_id and t.status = 'active'
    join public.organization_product_routes r on r.id = t.route_id and r.status = 'active' and r.org_agreement_id = p_agreement
    join public.commercial_conditions k on k.product_table_version_id = pv.id and k.contract_type_id = p_contract_type
      and p_term between k.term_min and k.term_max
    where pv.organization_id = p_org and pv.status = 'published'
      and coalesce(pv.effective_from, pv.published_at, pv.created_at) <= now()
      and (pv.effective_until is null or now() < pv.effective_until)
    order by pv.id, (k.amount_min is not null) desc, k.amount_min desc nulls last
  loop
    -- A table with amount bands: the band is found after the amount is known (by installment the amount depends on the factor).
    for o in
      select private.offer_for(x.version_id, k.id, p_agreement, p_contract_type, p_term, p_mode, p_value, p_outstanding, v_on)
      from public.commercial_conditions k
      where k.product_table_version_id = x.version_id and k.contract_type_id = p_contract_type and p_term between k.term_min and k.term_max
      order by k.amount_min nulls last
    loop
      if o is not null then v_out := v_out || jsonb_build_array(o); exit; end if;
    end loop;
  end loop;
  -- Best first: by amount the lowest installment; by installment the highest amount.
  return coalesce((select jsonb_agg(e order by case when p_mode = 'amount' then (e->>'installment')::numeric else -(e->>'amount')::numeric end, e->>'table_name')
                   from jsonb_array_elements(v_out) e), '[]'::jsonb);
end
$$;

create or replace function public.save_simulation_offer(p_customer uuid, p_table_version uuid, p_condition uuid, p_agreement uuid,
                                                        p_contract_type uuid, p_term integer, p_mode text, p_value numeric,
                                                        p_outstanding numeric default null)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v_customer public.clients%rowtype; o jsonb; v_id uuid; v_on date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into v_customer from public.clients where id = p_customer and deleted_at is null;
  if v_customer.id is null or not public.is_active_organization_member(v_customer.organization_id) then raise exception 'customer_not_found_or_forbidden'; end if;
  if p_mode not in ('amount', 'installment') or p_value is null or p_value <= 0 or p_term is null then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from public.product_table_versions pv join public.product_tables t on t.id = pv.product_table_id
                 join public.organization_product_routes r on r.id = t.route_id
                 where pv.id = p_table_version and pv.organization_id = v_customer.organization_id and pv.status = 'published'
                   and r.org_agreement_id = p_agreement) then
    raise exception 'published_table_version_not_available';
  end if;
  -- Recalculated here: what the screen showed is never trusted.
  o := private.offer_for(p_table_version, p_condition, p_agreement, p_contract_type, p_term, p_mode, p_value, p_outstanding, v_on);
  if o is null then raise exception 'offer_not_available'; end if;
  if p_outstanding is not null and (o->>'change')::numeric < 0 then raise exception 'outstanding_above_amount'; end if;

  perform set_config('corban.simulation_rpc', 'on', true);
  insert into public.simulations (organization_id, customer_id, product_table_version_id, status, requested_amount, released_amount,
                                  installment_amount, term, rate, coefficient, input_snapshot, result_snapshot, created_by)
  values (v_customer.organization_id, v_customer.id, p_table_version, 'calculated', (o->>'amount')::numeric,
          coalesce((o->>'change')::numeric, (o->>'amount')::numeric), (o->>'installment')::numeric, p_term,
          nullif(o->>'rate', '')::numeric, (o->>'factor')::numeric,
          jsonb_build_object('mode', p_mode, 'value', round(p_value, 2), 'term', p_term, 'agreement_id', p_agreement,
                             'contract_type_id', p_contract_type, 'condition_id', p_condition, 'outstanding', round(p_outstanding, 2),
                             'pricing_effective_at', now(), 'factor_date', o->>'factor_date'),
          jsonb_build_object('calculation', case when p_mode = 'amount' then 'amount_x_factor' else 'installment_div_factor' end,
                             'factor', o->'factor', 'factor_source', o->'factor_source', 'change', o->'change'),
          auth.uid())
  returning id into v_id;
  perform set_config('corban.simulation_rpc', 'off', true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc', 'off', true);
  raise;
end
$$;

revoke all on function private.offer_for(uuid, uuid, uuid, uuid, integer, text, numeric, numeric, date) from public, anon, authenticated;
grant execute on function private.offer_for(uuid, uuid, uuid, uuid, integer, text, numeric, numeric, date) to authenticated;
revoke all on function public.simulation_offers(uuid, uuid, uuid, integer, text, numeric, numeric, date) from public, anon;
revoke all on function public.save_simulation_offer(uuid, uuid, uuid, uuid, uuid, integer, text, numeric, numeric) from public, anon;
grant execute on function public.simulation_offers(uuid, uuid, uuid, integer, text, numeric, numeric, date) to authenticated;
grant execute on function public.save_simulation_offer(uuid, uuid, uuid, uuid, uuid, integer, text, numeric, numeric) to authenticated;
