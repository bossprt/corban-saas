-- Saldo devedor, banco de origem and nº do contrato de origem on the contract (owner request 01/10/2026). Record only:
-- the commission keeps using the gross or net amount, as each table line says. Asked on the proposal forms and the
-- broker portal when the contract type is not "Novo" (refinancing, portability, debt purchase), editable in the
-- contract with history, never a reason to recalculate. Optional.

alter table public.proposals_v2
  add column outstanding_balance numeric(15,2) check (outstanding_balance is null or outstanding_balance >= 0),
  add column origin_bank_name text check (origin_bank_name is null or length(origin_bank_name) between 1 and 120),
  add column origin_contract_number text check (origin_contract_number is null or length(origin_contract_number) between 1 and 60);

-- The three values from a form (decimal text for the money, never a float); empty means not informed.
create or replace function private.contract_origin_details(p jsonb, out outstanding_balance numeric, out origin_bank_name text, out origin_contract_number text)
language plpgsql
immutable
set search_path to ''
as $$
declare v text;
begin
  v := nullif(btrim(coalesce(p->>'outstanding_balance', '')), '');
  if v is not null and v !~ '^[0-9]{1,13}(\.[0-9]{1,2})?$' then raise exception 'invalid_outstanding_balance'; end if;
  outstanding_balance := v::numeric;
  origin_bank_name := nullif(btrim(coalesce(p->>'origin_bank_name', '')), '');
  if length(origin_bank_name) > 120 then raise exception 'invalid_origin_bank'; end if;
  origin_contract_number := nullif(btrim(coalesce(p->>'origin_contract_number', '')), '');
  if length(origin_contract_number) > 60 then raise exception 'invalid_origin_contract'; end if;
end
$$;
revoke all on function private.contract_origin_details(jsonb) from public, anon, authenticated;

-- The typed creators gain the details (a defaulted parameter, so every existing call keeps working).
drop function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, integer, text, text, uuid);
drop function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text, uuid);

CREATE OR REPLACE FUNCTION public.create_direct_proposal(p_org uuid, p_customer_id uuid, p_table_version_id uuid, p_seller_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_stage text, p_contract_type_id uuid, p_details jsonb DEFAULT NULL::jsonb)
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
  d record;
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
  select * into d from private.contract_origin_details(p_details);

  -- Same bank + ADE: the proposal already exists.
  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    select e.proposal_id into v_existing from public.proposal_external_identities e
    where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade;
    if v_existing is not null then return query select v_existing, true; return; end if;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by, contract_type_id,
                                   outstanding_balance, origin_bank_name, origin_contract_number)
  values (p_org, p_customer_id, null, p_table_version_id, case when p_stage = 'submitted' then 'submitted' else 'digitization' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_client.full_name, 'cpf', v_client.cpf),
          jsonb_build_object('origin', 'direct', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          p_seller_id, auth.uid(), p_contract_type_id, d.outstanding_balance, d.origin_bank_name, d.origin_contract_number)
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

CREATE OR REPLACE FUNCTION public.submit_broker_proposal(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_table_version_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_contract_type_id uuid, p_details jsonb DEFAULT NULL::jsonb)
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
  d record;
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
  select * into d from private.contract_origin_details(p_details);

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
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by, contract_type_id,
                                   outstanding_balance, origin_bank_name, origin_contract_number)
  values (p_org, v_client, null, p_table_version_id, case when v_ade is null then 'digitization' else 'submitted' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_name, 'cpf', v_cpf, 'phone', v_phone, 'email', v_email),
          jsonb_build_object('origin', 'portal', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          v_seller, auth.uid(), p_contract_type_id, d.outstanding_balance, d.origin_bank_name, d.origin_contract_number)
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

-- Contract edit: the origin data is editable and recorded, without recalculating.
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
  d record;
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
  if p_data ?| array['outstanding_balance', 'origin_bank_name', 'origin_contract_number'] then
    select * into d from private.contract_origin_details(jsonb_build_object(
      'outstanding_balance', case when p_data ? 'outstanding_balance' then p_data->>'outstanding_balance' else p.outstanding_balance::text end,
      'origin_bank_name', case when p_data ? 'origin_bank_name' then p_data->>'origin_bank_name' else p.origin_bank_name end,
      'origin_contract_number', case when p_data ? 'origin_contract_number' then p_data->>'origin_contract_number' else p.origin_contract_number end));
    n.outstanding_balance := d.outstanding_balance; n.origin_bank_name := d.origin_bank_name; n.origin_contract_number := d.origin_contract_number;
  end if;
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
  if n.outstanding_balance is distinct from p.outstanding_balance then v_changes := v_changes || jsonb_build_object('outstanding_balance', jsonb_build_object('from', p.outstanding_balance, 'to', n.outstanding_balance)); end if;
  if n.origin_bank_name is distinct from p.origin_bank_name then v_changes := v_changes || jsonb_build_object('origin_bank_name', jsonb_build_object('from', p.origin_bank_name, 'to', n.origin_bank_name)); end if;
  if n.origin_contract_number is distinct from p.origin_contract_number then v_changes := v_changes || jsonb_build_object('origin_contract_number', jsonb_build_object('from', p.origin_contract_number, 'to', n.origin_contract_number)); end if;
  if n.term is distinct from p.term then v_changes := v_changes || jsonb_build_object('term', jsonb_build_object('from', p.term, 'to', n.term)); end if;
  if n.formalization is distinct from p.formalization then v_changes := v_changes || jsonb_build_object('formalization', jsonb_build_object('from', p.formalization, 'to', n.formalization)); end if;
  if n.paid_to_client_on is distinct from p.paid_to_client_on then v_changes := v_changes || jsonb_build_object('paid_to_client_on', jsonb_build_object('from', p.paid_to_client_on, 'to', n.paid_to_client_on)); end if;
  if v_changes = '{}'::jsonb then return; end if;

  perform set_config('corban.contract_edit_rpc', 'on', true);
  update public.proposals_v2
  set product_table_version_id = n.product_table_version_id, seller_id = n.seller_id, requested_amount = n.requested_amount,
      released_amount = n.released_amount, installment_amount = n.installment_amount, term = n.term,
      commercial_snapshot = n.commercial_snapshot, formalization = n.formalization, paid_to_client_on = n.paid_to_client_on,
      contract_type_id = n.contract_type_id, outstanding_balance = n.outstanding_balance, origin_bank_name = n.origin_bank_name,
      origin_contract_number = n.origin_contract_number, updated_at = now()
  where id = p.id;
  perform set_config('corban.contract_edit_rpc', 'off', true);

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'edit', v_changes, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);

  -- A calculated contract follows its new data at once; if the calculation cannot (no line for the new term, a payout
  -- change above the new receipt...), the whole edit is refused.
  -- Formalization, the paid date and the origin data (saldo devedor, banco e contrato de origem) do not change the
  -- commission: no recalculation for them.
  if (v_changes - 'formalization' - 'paid_to_client_on' - 'outstanding_balance' - 'origin_bank_name' - 'origin_contract_number') <> '{}'::jsonb
     and exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then
    perform public.calculate_contract_commission(p.id);
    for x in select * from private.contract_payable(p.id) loop
      if x.payable > x.received then raise exception 'override_exceeds_received'; end if;
    end loop;
  elsif (v_changes - 'formalization' - 'paid_to_client_on' - 'outstanding_balance' - 'origin_bank_name' - 'origin_contract_number') <> '{}'::jsonb then
    -- Not calculated yet (e.g. the type was missing): try now; a failure is recorded on the contract, the edit stays.
    perform private.try_auto_calculate(p.id);
  end if;
end
$function$;

revoke all on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, integer, text, text, uuid, jsonb) from public, anon;
grant execute on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, integer, text, text, uuid, jsonb) to authenticated;
revoke all on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text, uuid, jsonb) from public, anon;
grant execute on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text, uuid, jsonb) to authenticated;
