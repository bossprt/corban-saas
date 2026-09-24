-- F5 step 0: remove the ChatGPT-era network, import, financial-evidence and integration-hub models (owner approved
-- blocks 1, 2 and 3; every table below had zero rows in production except profiles (2), integration_adapters (2) and
-- integration_field_mappings (4), which are configuration leftovers with no consumer).
--   block 1  network model (entities, relationships, channels, channel/split rules, route snapshots, seller sub-rules,
--            supervisions, component payout policies) and the unused profiles table. Replaced by the F4 engine
--            (commission_rule_versions, proposal_commission_calcs/lines).
--   block 2  import pipeline (sources, batches, raw/normalized rows, match candidates, decisions, conflicts),
--            financial events/evidence/reconciliation cases. Replaced by the F5 receipt model in the next migration.
--   block 3  integration hub (adapters, field mappings, source bindings, runs, artifacts). F8 rebuilds connectors on the
--            receipt model.
-- Functions that stay are rewritten first so no surviving code references a dropped relation.

-- Surviving functions ------------------------------------------------------------------------------------------------

-- Same-tenant guard now only serves proposal_external_identities (bank + ADE identity of a proposal).
create or replace function public.assert_same_organization_reference()
returns trigger
language plpgsql
set search_path to ''
as $$
declare ref_org uuid;
begin
  if tg_table_name = 'proposal_external_identities' then
    select organization_id into ref_org from public.proposals_v2 where id = new.proposal_id;
    if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_proposal'; end if;
  end if;
  return new;
end
$$;

-- A draft proposal's seller can change until it leaves draft (the commercial route snapshot no longer exists; the
-- commission is frozen by calculate_proposal_commission instead).
create or replace function public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_org uuid;
  v_seller public.commercial_sellers%rowtype;
  v_attr jsonb;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select p.organization_id, p.attribution_snapshot into v_org, v_attr
  from public.proposals_v2 p
  where p.id = p_proposal_id and p.status = 'draft' and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_org, array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;

  if p_seller_id is not null then
    select * into v_seller from public.commercial_sellers s where s.id = p_seller_id and s.organization_id = v_org and s.is_active;
    if not found then raise exception 'active_seller_not_found'; end if;
    v_attr := coalesce(v_attr, '{}'::jsonb) || jsonb_build_object('seller', jsonb_build_object(
      'id', v_seller.id, 'name', v_seller.name, 'category', v_seller.seller_category, 'seller_group_id', v_seller.seller_group_id, 'assigned_at', now()));
  else
    v_attr := coalesce(v_attr, '{}'::jsonb) - 'seller';
  end if;

  perform set_config('corban.proposal_seller_rpc', 'on', true);
  update public.proposals_v2 set seller_id = p_seller_id, attribution_snapshot = v_attr, updated_at = now()
  where id = p_proposal_id and organization_id = v_org;
  perform set_config('corban.proposal_seller_rpc', 'off', true);

  return p_proposal_id;
end
$$;

create or replace function public.guard_proposal_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_user in ('authenticated','anon','service_role')
     and current_setting('corban.proposal_rpc', true) is distinct from 'on'
     and current_setting('corban.paid_evidence_rpc', true) is distinct from 'on'
     and current_setting('corban.proposal_seller_rpc', true) is distinct from 'on' then
    raise exception 'proposal_write_requires_governed_rpc';
  end if;

  if tg_op = 'UPDATE' and new.seller_id is distinct from old.seller_id then
    if current_setting('corban.proposal_seller_rpc', true) is distinct from 'on' then raise exception 'proposal_seller_change_requires_governed_rpc'; end if;
    if old.status <> 'draft' then raise exception 'proposal_seller_is_frozen'; end if;
  end if;

  if tg_op = 'UPDATE' and (
     new.id is distinct from old.id
     or new.organization_id is distinct from old.organization_id
     or new.customer_id is distinct from old.customer_id
     or new.simulation_id is distinct from old.simulation_id
     or new.product_table_version_id is distinct from old.product_table_version_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at) then
    raise exception 'proposal_identity_is_immutable';
  end if;
  return new;
end
$$;

create or replace function public.bootstrap_organization_admin(p_platform_actor_user_id uuid, p_user_id uuid, p_organization_name text, p_organization_document text, p_plan_type text default 'founder')
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_org_id uuid;
begin
  if not exists (select 1 from public.platform_administrators pa where pa.user_id = p_platform_actor_user_id and pa.status = 'active') then raise exception 'active_platform_admin_required'; end if;
  if p_user_id is null then raise exception 'user_id_required'; end if;
  if nullif(btrim(p_organization_name), '') is null then raise exception 'organization_name_required'; end if;
  if nullif(btrim(p_organization_document), '') is null then raise exception 'organization_document_required'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then raise exception 'auth_user_not_found'; end if;
  if exists (select 1 from public.organization_memberships m where m.user_id = p_user_id and m.status = 'active') then raise exception 'user_already_has_active_membership'; end if;
  insert into public.organizations (name, document, plan_type, is_active) values (btrim(p_organization_name), btrim(p_organization_document), p_plan_type, true) returning id into v_org_id;
  insert into public.organization_memberships (organization_id, user_id, role, status) values (v_org_id, p_user_id, 'admin', 'active');
  insert into public.platform_admin_audit_events (actor_user_id, action, target_user_id, organization_id, metadata)
  values (p_platform_actor_user_id, 'organization.bootstrap_admin', p_user_id, v_org_id, jsonb_build_object('plan_type', p_plan_type));
  return v_org_id;
end
$$;

-- Only table-condition components remain under this guard (component payout policies are gone).
create or replace function public.guard_component_commission_write()
returns trigger
language plpgsql
set search_path to ''
as $$
declare v_status text;
begin
  select v.status into v_status
  from public.commercial_conditions c
  join public.product_table_versions v on v.id = c.product_table_version_id and v.organization_id = c.organization_id
  where c.id = coalesce(new.condition_id, old.condition_id) and c.organization_id = coalesce(new.organization_id, old.organization_id);
  if v_status is distinct from 'draft' then raise exception 'published_version_components_are_immutable'; end if;
  if current_user in ('authenticated','anon') and current_setting('corban.component_condition_rpc', true) is distinct from 'on' then
    raise exception 'component_condition_write_requires_governed_rpc';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if tg_op = 'INSERT' and current_user in ('authenticated','anon') then new.created_by := auth.uid(); end if;
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.condition_id is distinct from old.condition_id
       or new.component_type_id is distinct from old.component_type_id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
      raise exception 'component_identity_is_immutable';
    end if;
    new.updated_at := now();
  end if;
  return new;
end
$$;

create or replace function public.guard_factor_batch()
returns trigger
language plpgsql
set search_path to ''
as $$
declare v_org uuid;
begin
  select p.organization_id into v_org from public.commercial_factor_profiles p where p.id = coalesce(new.profile_id, old.profile_id);
  if v_org is distinct from coalesce(new.organization_id, old.organization_id) then raise exception 'factor_profile_cross_tenant'; end if;

  if tg_op = 'INSERT' then
    if current_user in ('authenticated','anon') and new.status <> 'draft' then raise exception 'factor_batch_must_start_draft'; end if;
    if current_user in ('authenticated','anon') then new.created_by := auth.uid(); end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.status = 'published' then raise exception 'published_factor_batch_is_immutable'; end if;
    return old;
  end if;

  if old.status = 'published' then raise exception 'published_factor_batch_is_immutable'; end if;
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.profile_id is distinct from old.profile_id
     or new.effective_date is distinct from old.effective_date or new.revision is distinct from old.revision or new.source_kind is distinct from old.source_kind
     or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'factor_batch_identity_is_immutable';
  end if;
  if old.status = 'draft' and new.status = 'published' then
    if current_user in ('authenticated','anon') and current_setting('corban.factor_publish', true) is distinct from 'on' then raise exception 'factor_publish_requires_governed_rpc'; end if;
    new.published_at := coalesce(new.published_at, now());
  elsif new.status is distinct from old.status then
    raise exception 'invalid_factor_batch_transition';
  end if;
  return new;
end
$$;

-- Supervisor visibility follows the team (the seller's user reports to the caller), like the data scope of F1.
create or replace function public.can_view_seller_profile(p_org uuid, p_seller uuid)
returns boolean
language sql
stable
set search_path to ''
as $$
  select public.has_active_organization_role(p_org, array['admin','manager'])
    or exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and s.id = p_seller and s.user_id = auth.uid() and s.is_active)
    or (public.has_active_organization_role(p_org, array['supervisor'])
        and exists (select 1 from public.commercial_sellers s
                    join public.organization_memberships m on m.organization_id = s.organization_id and m.user_id = s.user_id and m.status = 'active'
                    where s.organization_id = p_org and s.id = p_seller and m.team_leader_user_id = auth.uid()))
$$;

-- Smart import of commercial tables: the component payout policy attachment is gone; everything else is unchanged.
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
      v_effective_from:=case when nullif(rowj->>'effective_from','') is null then null else (rowj->>'effective_from')::timestamptz end;
      v_effective_until:=case when nullif(rowj->>'effective_until','') is null then null else (rowj->>'effective_until')::timestamptz end;
      v_factor_mode:=nullif(rowj->>'factor_mode','');
      v_factor_value:=case when nullif(rowj->>'factor_value','') is null then null else (rowj->>'factor_value')::numeric end;
      v_factor_date:=case when nullif(rowj->>'factor_date','') is null then coalesce(v_effective_from::date,current_date) else (rowj->>'factor_date')::date end;
    exception when others then raise exception 'invalid_smart_import_row'; end;

    if v_bank_name is null or length(v_bank_name)>120
       or v_agreement_name is null or length(v_agreement_name)>120
       or v_table_name is null or length(v_table_name)>120
       or v_term_min not between 1 and 600
       or v_term_max not between 1 and 600
       or v_term_min>v_term_max
       or (v_coefficient is null and v_rate is null)
       or (v_coefficient is not null and v_coefficient<0)
       or (v_rate is not null and v_rate<0)
       or (v_effective_from is not null and v_effective_until is not null and v_effective_until<v_effective_from)
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
      and ((p_provider is null and x.org_provider_id is null) or x.org_provider_id=p_provider)
      and x.production_origin=p_production_origin
    limit 1;
    if v_route.id is null then
      insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status)
      values(p_organization,v_bank.id,p_provider,v_agreement.id,p_production_origin,'active') returning * into v_route;
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
    limit 1;

    perform set_config('corban.condition_rpc','on',true);
    if v_condition.id is null then
      insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate,created_by)
      values(p_organization,v_version.id,v_contract.id,v_term_min,v_term_min,v_term_max,v_coefficient,v_rate,auth.uid())
      returning * into v_condition;
    else
      update public.commercial_conditions
      set term=v_term_min,term_min=v_term_min,term_max=v_term_max,coefficient=v_coefficient,rate=v_rate,updated_at=now()
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
end $function$
;


-- Manual 'paid' evidence no longer carries an import decision.
CREATE OR REPLACE FUNCTION public.move_operational_case(p_case_id uuid, p_to_state text, p_note text DEFAULT NULL::text, p_pendency_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.operational_cases%rowtype;
  v_stage uuid;
  v_sla integer;
  v_status text;
begin
  select * into c from public.operational_cases where id = p_case_id for update;
  if not found or not public.is_active_organization_member(c.organization_id) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  -- The caller must see the proposal (scope) and be allowed to edit the pipeline.
  if not exists (
    select 1 from public.proposals_v2 p
    where p.id = c.proposal_id and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
  ) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  if not public.has_permission(c.organization_id, 'esteira.edit') then raise exception 'not_authorized'; end if;

  if not (
    (p_to_state = 'pending_external' and c.canonical_state in ('submitted','approved')) or
    (p_to_state = 'submitted' and c.canonical_state = 'pending_external') or
    (p_to_state = 'paid' and c.canonical_state in ('submitted','pending_external','approved'))
  ) then
    -- Not one of the new moves: the governed transition decides (and enforces its own rules).
    return public.transition_operational_case(p_case_id, p_to_state, null);
  end if;

  if p_to_state in ('pending_external','paid') and (p_note is null or length(btrim(p_note)) < 3) then raise exception 'note_required'; end if;
  if p_to_state = 'pending_external' and (p_pendency_due_at is null or p_pendency_due_at < now()) then raise exception 'pendency_due_required'; end if;

  select s.id, s.sla_minutes into v_stage, v_sla from public.operational_stages s
  where s.organization_id = c.organization_id and s.canonical_state = p_to_state and s.is_active
  order by s.sort_order, s.created_at limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc', 'on', true);
  perform set_config('corban.proposal_rpc', 'on', true);
  update public.operational_cases
  set current_stage_id = v_stage,
      canonical_state = p_to_state,
      entered_stage_at = now(),
      due_at = case when v_sla is null then null else now() + make_interval(mins => v_sla) end,
      pendency_reason = case when p_to_state = 'pending_external' then btrim(p_note) else null end,
      pendency_due_at = case when p_to_state = 'pending_external' then p_pendency_due_at else null end,
      updated_at = now()
  where id = c.id;

  select p.status into v_status from public.proposals_v2 p where p.id = c.proposal_id for update;
  if p_to_state = 'paid' then
    -- The proposal status machine only allows approved -> paid.
    if v_status in ('digitization') then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
      v_status := 'submitted';
    end if;
    if v_status = 'submitted' then
      update public.proposals_v2 set status = 'approved', updated_at = now() where id = c.proposal_id;
    end if;
    perform set_config('corban.paid_evidence_rpc', 'on', true);
    update public.proposals_v2 set status = 'paid', updated_at = now() where id = c.proposal_id;
    insert into public.proposal_status_evidence (organization_id, proposal_id, canonical_status, raw_status, evidenced_at, created_by, source, note)
    values (c.organization_id, c.proposal_id, 'paid', 'manual', now(), auth.uid(), 'manual', btrim(p_note));
    perform set_config('corban.paid_evidence_rpc', 'off', true);
  elsif v_status not in ('submitted') and p_to_state in ('submitted','pending_external') then
    if v_status = 'digitization' then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
    end if;
  end if;

  insert into public.operational_events (organization_id, operational_case_id, event_type, from_state, to_state, source, actor_user_id, metadata)
  values (c.organization_id, c.id, 'state_transition', c.canonical_state, p_to_state, 'corban_os', auth.uid(),
          jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''), 'pendency_due_at', p_pendency_due_at));
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return p_to_state;
end
$function$
;


-- Columns of surviving tables that pointed at removed models ------------------------------------------------------------

alter table public.proposal_external_identities drop column channel_id;
alter table public.proposal_status_evidence drop column import_decision_id;
alter table public.commercial_factor_batches drop column import_batch_id;

-- Tables (no CASCADE: anything unexpected still depending on them aborts the migration) ---------------------------------

drop table
  -- block 1
  public.proposal_seller_commission_snapshots, public.proposal_commercial_component_snapshots, public.proposal_commercial_snapshots,
  public.commission_rule_components, public.channel_commission_rule_versions, public.network_split_rule_versions,
  public.commercial_channels, public.commercial_relationships, public.commercial_entities,
  public.seller_sub_rule_versions, public.seller_supervisions,
  public.commercial_condition_component_policy, public.component_payout_policy_items, public.component_payout_policy_versions, public.component_payout_policies,
  public.profiles,
  -- block 2
  public.financial_evidence_links, public.financial_reconciliation_cases, public.financial_events,
  public.import_applied_decisions, public.import_decisions, public.import_match_candidates, public.import_conflict_rows, public.import_conflicts,
  public.import_normalized_rows, public.import_raw_rows,
  -- block 3 (before import_batches / import_sources, which they reference)
  public.integration_run_artifacts, public.integration_runs, public.integration_source_bindings, public.integration_field_mappings, public.integration_adapters,
  public.import_batches, public.import_sources, public.product_table_external_identities;

-- Functions of the removed models -----------------------------------------------------------------------------------------

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','private') and p.proname = any (array[
      'attach_import_batch_adapter','commercial_route','import_row_evidence','list_import_rows','apply_approved_import_match',
      'can_view_seller_commission','cancel_integration_run','claim_integration_run','complete_integration_run','confirm_proposal_paid_from_import',
      'create_and_publish_commission_rule','create_and_publish_split_rule','create_integration_reexecution','enqueue_integration_run','fail_integration_run',
      'freeze_import_source_financial_semantic','freeze_proposal_commercial_route','generate_import_match_candidates','get_commercial_route','get_user_organization_id',
      'guard_condition_component_policy','guard_financial_event_insert','guard_import_batch_adapter_contract','guard_import_conflict_row_write','guard_import_conflict_write',
      'guard_import_normalized_row_consistency','guard_import_raw_row_immutable','guard_integration_artifact_consistency','guard_integration_artifact_write',
      'guard_integration_run_consistency','guard_integration_run_state','ingest_normalized_import_batch','list_dispatchable_integration_runs',
      'publish_expected_commission','publish_financial_evidence_event','publish_financial_fact_from_import_decision','publish_financial_reversal',
      'publish_seller_sub_rule','record_import_conflicts','refresh_financial_reconciliation','resolve_component_payout_policy','resolve_import_conflict',
      'resolve_seller_sub_rule','save_component_payout_policy','set_seller_supervision','snapshot_seller_commission','snapshot_seller_commission_after_component',
      'sweep_orphaned_integration_runs'])
  loop
    execute format('drop function %s', f);
  end loop;
end
$$;
