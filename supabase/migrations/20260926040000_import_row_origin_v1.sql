-- Import rows carry their own origin (owner decision 26/09/2026, ADR-0038).
--
-- The tables search now exports the current vigência of every table the filters show (one bank, or all), with a
-- "Promotora parceira" column, so the owner edits tax or values in Excel and imports the file back. One file can then
-- mix own production and tables sold through partner companies (Daycoval comes through Bevicred and Efetivamais), so
-- each row may say its own origin: production_origin ('own' | 'third_party') and provider_id (an active partner of the
-- company). A row without them keeps the origin chosen on the import screen, as before. Everything else is unchanged.

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
       or (v_coefficient is null and v_rate is null)
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
      insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate,tax_pct,created_by)
      values(p_organization,v_version.id,v_contract.id,v_term_min,v_term_min,v_term_max,v_coefficient,v_rate,trim_scale(coalesce(v_tax,0)),auth.uid())
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
