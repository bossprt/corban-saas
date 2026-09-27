-- Part C5 (1 of 2): removal of the ChatGPT-era global reference catalog (owner approved 27/09/2026, ADR-0043).
--
-- Every company registers its own banks, agreements and partners (organization_banks, organization_agreements,
-- organization_providers); the global catalog (banks, agreements, providers, products, modalities) was only read by
-- the old /app/catalogo screen and the platform page. Checked in production: no route points to the global catalog
-- (0 of 4 routes), agreements/providers/products/modalities are empty, banks has 34 reference rows. The document
-- types, checklists and the digitization queue stay (the operational team types contracts for brokers).
--
-- Backup first: schema backup_c5 (not exposed by the API), removed only with the owner's approval.

create schema backup_c5;
revoke all on schema backup_c5 from public, anon, authenticated;
create table backup_c5.banks as select * from public.banks;
create table backup_c5.agreements as select * from public.agreements;
create table backup_c5.providers as select * from public.providers;
create table backup_c5.products as select * from public.products;
create table backup_c5.modalities as select * from public.modalities;
revoke all on all tables in schema backup_c5 from public, anon, authenticated;

-- Proposals take the bank name from the company's own registration only.
CREATE OR REPLACE FUNCTION public.create_direct_proposal(p_org uuid, p_customer_id uuid, p_table_version_id uuid, p_seller_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text, p_stage text)
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

  -- Same bank + ADE: the proposal already exists.
  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    select e.proposal_id into v_existing from public.proposal_external_identities e
    where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade;
    if v_existing is not null then return query select v_existing, true; return; end if;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by)
  values (p_org, p_customer_id, null, p_table_version_id, case when p_stage = 'submitted' then 'submitted' else 'digitization' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_client.full_name, 'cpf', v_client.cpf),
          jsonb_build_object('origin', 'direct', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          p_seller_id, auth.uid())
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

CREATE OR REPLACE FUNCTION public.submit_broker_proposal(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_table_version_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text)
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
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by)
  values (p_org, v_client, null, p_table_version_id, case when v_ade is null then 'digitization' else 'submitted' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_name, 'cpf', v_cpf, 'phone', v_phone, 'email', v_email),
          jsonb_build_object('origin', 'portal', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          v_seller, auth.uid())
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

-- Routes: only the company's own bank, agreement and partner.
alter table public.organization_product_routes drop constraint organization_product_routes_shape;
alter table public.organization_product_routes drop constraint organization_product_routes_unique;
alter table public.organization_product_routes
  drop column bank_id, drop column provider_id, drop column agreement_id, drop column product_id, drop column modality_id;
alter table public.organization_product_routes add constraint organization_product_routes_shape check (
  org_bank_id is not null and org_agreement_id is not null and production_origin is not null
  and ((production_origin = 'own' and org_provider_id is null) or (production_origin = 'third_party' and org_provider_id is not null)));

drop table public.modalities;
drop table public.products;
drop table public.agreements;
drop table public.providers;
drop table public.banks;
