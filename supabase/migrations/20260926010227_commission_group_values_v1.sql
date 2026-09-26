-- Commission tables by seller group, part B of the payout bridge (owner decision 25/09/2026, ADR-0036).
--
-- Every line of a commission table (a condition) already holds what the company receives per commission type
-- (commercial_condition_components). Now it also holds, for each seller group and each type, the value that group
-- gets: a % of the operation or a fixed R$ (the 2tech layout: one block of columns per group). An empty cell means the
-- type does not apply to the group. Own-production groups have no values (the company keeps everything).
--
-- Written only through replace_condition_group_values, only while the table version is a draft; published versions
-- are immutable. The one exception is the conversion below, which translates today's shares once:
-- value = what the company receives for the type x the group's share / 100 (e.g. 40% of 5% = 2), exact numeric.
-- Nothing is deleted: the old shares stay until part C moves the calculation to the new values.
-- The smart import now writes group values when the file brings group columns.

create table public.commercial_condition_group_values (
  organization_id uuid not null,
  condition_id uuid not null,
  group_id uuid not null,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  value_kind text not null check (value_kind in ('percentage', 'fixed_brl')),
  value numeric not null check (value >= 0 and (value_kind <> 'percentage' or value <= 100)),
  source text not null check (source in ('converted', 'import', 'manual')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (condition_id, group_id, component_type_id),
  foreign key (organization_id, condition_id) references public.commercial_conditions(organization_id, id) on delete cascade,
  foreign key (organization_id, group_id) references public.commission_groups(organization_id, id) on delete restrict
);
create index commercial_condition_group_values_org_idx on public.commercial_condition_group_values (organization_id, condition_id);
create index commercial_condition_group_values_group_idx on public.commercial_condition_group_values (organization_id, group_id);
create index commercial_condition_group_values_type_idx on public.commercial_condition_group_values (component_type_id);
create index commercial_condition_group_values_created_by_idx on public.commercial_condition_group_values (created_by);

create or replace function private.guard_condition_group_value_write()
returns trigger
language plpgsql
set search_path to ''
as $$
declare v_status text;
begin
  if current_setting('corban.group_values_conversion', true) = 'on' then return coalesce(new, old); end if;
  select v.status into v_status
  from public.commercial_conditions c
  join public.product_table_versions v on v.id = c.product_table_version_id and v.organization_id = c.organization_id
  where c.id = coalesce(new.condition_id, old.condition_id);
  -- A draft line removed takes its values with it (in the cascade the line is already gone); everything else needs the
  -- governed function and a draft.
  if tg_op = 'DELETE' and v_status is null then return old; end if;
  if v_status is distinct from 'draft' then raise exception 'published_version_values_are_immutable'; end if;
  if tg_op = 'DELETE' then return old; end if;
  if current_setting('corban.group_values_rpc', true) is distinct from 'on' then raise exception 'group_values_require_governed_rpc'; end if;
  return new;
end
$$;
revoke all on function private.guard_condition_group_value_write() from public, anon, authenticated;
create trigger commercial_condition_group_values_00_guard before insert or update or delete on public.commercial_condition_group_values
  for each row execute function private.guard_condition_group_value_write();

alter table public.commercial_condition_group_values enable row level security;
revoke all on public.commercial_condition_group_values from public, anon, authenticated;
grant select on public.commercial_condition_group_values to authenticated;
-- Same audience as the commission of the tables today: supervisor and above.
create policy commercial_condition_group_values_select on public.commercial_condition_group_values for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager', 'supervisor']));

-- Replace the group values of one draft line. p_values: [{"group_id","component_type_id","value_kind","value": "2.5", "source"?}]
-- (decimal text, never floating point).
create or replace function public.replace_condition_group_values(p_condition uuid, p_values jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.commercial_conditions%rowtype;
  it jsonb;
  v_group uuid;
  v_type uuid;
  v_kind text;
  v_value numeric;
  v_source text;
  n integer := 0;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into c from public.commercial_conditions x where x.id = p_condition;
  if c.id is null or not public.has_active_organization_role(c.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if not exists (select 1 from public.product_table_versions v where v.id = c.product_table_version_id and v.status = 'draft') then raise exception 'version_not_draft'; end if;
  if p_values is null or jsonb_typeof(p_values) <> 'array' or jsonb_array_length(p_values) > 700 then raise exception 'invalid_group_values'; end if;

  perform set_config('corban.group_values_rpc', 'on', true);
  delete from public.commercial_condition_group_values where condition_id = c.id;
  for it in select * from jsonb_array_elements(p_values) loop
    begin
      v_group := (it->>'group_id')::uuid;
      v_type := (it->>'component_type_id')::uuid;
    exception when others then
      raise exception 'invalid_group_values';
    end;
    v_kind := it->>'value_kind';
    v_source := coalesce(nullif(it->>'source', ''), 'manual');
    if coalesce(it->>'value', '') !~ '^[0-9]{1,9}(\.[0-9]{1,8})?$' then raise exception 'invalid_group_value'; end if;
    v_value := trim_scale((it->>'value')::numeric);
    if v_kind not in ('percentage', 'fixed_brl') or (v_kind = 'percentage' and v_value > 100) or v_source not in ('import', 'manual') then
      raise exception 'invalid_group_value';
    end if;
    if not exists (select 1 from public.commission_groups g where g.id = v_group and g.organization_id = c.organization_id and g.is_active) then
      raise exception 'group_not_found';
    end if;
    if exists (select 1 from public.commission_group_rules r where r.group_id = v_group and r.own_production
               and r.version = (select max(r2.version) from public.commission_group_rules r2 where r2.group_id = v_group)) then
      raise exception 'group_is_own_production';
    end if;
    if not exists (select 1 from public.commission_component_types t where t.id = v_type and t.is_active) then raise exception 'invalid_group_values'; end if;
    insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source, created_by)
    values (c.organization_id, c.id, v_group, v_type, v_kind, v_value, v_source, auth.uid())
    on conflict (condition_id, group_id, component_type_id) do nothing;
    if not found then raise exception 'duplicate_group_value'; end if;
    n := n + 1;
  end loop;
  perform set_config('corban.group_values_rpc', 'off', true);
  return n;
end
$$;
revoke all on function public.replace_condition_group_values(uuid, jsonb) from public, anon;
grant execute on function public.replace_condition_group_values(uuid, jsonb) to authenticated;

-- A new draft version that starts as a copy of another one (lines, company values, group values and the old shares),
-- so the commission can be changed by hand and published as a new "vigência". An existing draft is returned instead.
create or replace function public.clone_table_version(p_version uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  src public.product_table_versions%rowtype;
  v_draft uuid;
  v_next integer;
  c record;
  v_new_condition uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into src from public.product_table_versions where id = p_version;
  if src.id is null or not public.has_active_organization_role(src.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  select id into v_draft from public.product_table_versions where product_table_id = src.product_table_id and status = 'draft' order by version desc limit 1;
  if v_draft is not null then return v_draft; end if;

  select coalesce(max(version), 0) + 1 into v_next from public.product_table_versions where product_table_id = src.product_table_id;
  insert into public.product_table_versions (organization_id, product_table_id, version, status, term_min, term_max, rate, coefficient, metadata)
  values (src.organization_id, src.product_table_id, v_next, 'draft', src.term_min, src.term_max, src.rate, src.coefficient,
          coalesce(src.metadata, '{}'::jsonb) || jsonb_build_object('cloned_from', src.id))
  returning id into v_draft;

  perform set_config('corban.condition_rpc', 'on', true);
  perform set_config('corban.component_condition_rpc', 'on', true);
  perform set_config('corban.group_values_rpc', 'on', true);
  for c in select * from public.commercial_conditions where product_table_version_id = src.id order by term_min, id loop
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, coefficient, rate, created_by)
    values (c.organization_id, v_draft, c.contract_type_id, c.term, c.term_min, c.term_max, c.amount_min, c.amount_max, c.coefficient, c.rate, auth.uid())
    returning id into v_new_condition;
    insert into public.commercial_condition_components (organization_id, condition_id, component_type_id, value_kind, received_value, calculation_base, source, created_by)
    select organization_id, v_new_condition, component_type_id, value_kind, received_value, calculation_base, source, auth.uid()
    from public.commercial_condition_components where condition_id = c.id;
    insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source, created_by)
    select organization_id, v_new_condition, group_id, component_type_id, value_kind, value, source, auth.uid()
    from public.commercial_condition_group_values where condition_id = c.id;
    insert into public.commercial_condition_commissions (organization_id, condition_id, received_commission_pct, net_base_pct, policy_version_id)
    select organization_id, v_new_condition, received_commission_pct, net_base_pct, policy_version_id
    from public.commercial_condition_commissions where condition_id = c.id;
    insert into public.commercial_condition_shares (organization_id, condition_id, group_id, share_pct, effective_pct, source, policy_version_id)
    select organization_id, v_new_condition, group_id, share_pct, effective_pct, source, policy_version_id
    from public.commercial_condition_shares where condition_id = c.id;
  end loop;
  perform set_config('corban.group_values_rpc', 'off', true);
  perform set_config('corban.component_condition_rpc', 'off', true);
  perform set_config('corban.condition_rpc', 'off', true);
  return v_draft;
end
$$;
revoke all on function public.clone_table_version(uuid) from public, anon;
grant execute on function public.clone_table_version(uuid) to authenticated;

-- Change by hand what the company receives and what each group gets on one draft line, in one transaction.
create or replace function public.save_condition_values(p_condition uuid, p_components jsonb, p_group_values jsonb)
returns void
language plpgsql
set search_path to ''
as $$
begin
  perform public.replace_commercial_condition_components(p_condition, p_components);
  perform public.replace_condition_group_values(p_condition, p_group_values);
end
$$;
revoke all on function public.save_condition_values(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_condition_values(uuid, jsonb, jsonb) to authenticated;

-- The smart import writes the group values of each line it imports.
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

-- Conversion of the old shares into group values (own-production groups excluded). Runs once below; lines that already
-- have a value for the group and type are left as they are, so running it again changes nothing.
create or replace function private.convert_shares_to_group_values(p_org uuid default null)
returns bigint
language plpgsql
set search_path to ''
as $$
declare v_done bigint;
begin
  perform set_config('corban.group_values_conversion', 'on', true);
  insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source)
  select s.organization_id, s.condition_id, s.group_id, k.component_type_id, k.value_kind, trim_scale(k.received_value * s.share_pct / 100), 'converted'
  from public.commercial_condition_shares s
  join public.commercial_condition_components k on k.condition_id = s.condition_id and k.organization_id = s.organization_id
  where (p_org is null or s.organization_id = p_org)
    and not exists (select 1 from public.commission_group_rules r where r.group_id = s.group_id and r.own_production
                    and r.version = (select max(r2.version) from public.commission_group_rules r2 where r2.group_id = s.group_id))
  on conflict (condition_id, group_id, component_type_id) do nothing;
  get diagnostics v_done = row_count;
  perform set_config('corban.group_values_conversion', 'off', true);
  return v_done;
end
$$;
revoke all on function private.convert_shares_to_group_values(uuid) from public, anon, authenticated;

do $$
declare v_expected bigint; v_done bigint;
begin
  select count(*) into v_expected
  from public.commercial_condition_shares s
  join public.commercial_condition_components k on k.condition_id = s.condition_id and k.organization_id = s.organization_id
  where not exists (select 1 from public.commission_group_rules r where r.group_id = s.group_id and r.own_production
                    and r.version = (select max(r2.version) from public.commission_group_rules r2 where r2.group_id = s.group_id));
  v_done := private.convert_shares_to_group_values();
  if v_done <> v_expected then raise exception 'conversion_count_mismatch % <> %', v_done, v_expected; end if;
  raise notice 'converted % group values', v_done;
end
$$;
