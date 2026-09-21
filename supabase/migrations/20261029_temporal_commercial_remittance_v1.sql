-- CORBAN OS — Temporal commercial versions + complete/partial remittance V1

create or replace function public.guard_product_table_version_immutable()
returns trigger
language plpgsql
set search_path=''
as $
declare
  v_catalog_governed boolean:=coalesce(current_setting('corban.catalog_rpc',true),'')='on';
begin
  if old.status='draft' and new.status not in ('draft','published') then
    raise exception 'invalid_product_table_version_transition';
  end if;
  if old.status='published' and new.status not in ('published','superseded','expired') then
    raise exception 'invalid_product_table_version_transition';
  end if;
  if old.status in ('superseded','expired') and new.status is distinct from old.status then
    raise exception 'terminal_product_table_version_status';
  end if;

  if old.status<>'draft' then
    -- Commercial facts remain immutable after publication.
    if new.organization_id is distinct from old.organization_id
       or new.product_table_id is distinct from old.product_table_id
       or new.version is distinct from old.version
       or new.effective_from is distinct from old.effective_from
       or new.term_min is distinct from old.term_min
       or new.term_max is distinct from old.term_max
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.metadata is distinct from old.metadata
       or new.created_at is distinct from old.created_at
    then
      raise exception 'published_product_table_version_is_immutable';
    end if;

    -- Only governed catalog/remittance code may close a published interval.
    if new.effective_until is distinct from old.effective_until and not v_catalog_governed then
      raise exception 'published_product_table_version_is_immutable';
    end if;
  end if;
  return new;
end
$;

create or replace function public.publish_product_table_version(p_version_id uuid)
returns uuid
language plpgsql
set search_path=''
as $$
declare
  v public.product_table_versions%rowtype;
  v_start timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select * into v
  from public.product_table_versions x
  where x.id=p_version_id
  for update;

  if not found then raise exception 'version_not_found'; end if;
  if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if v.status<>'draft' then raise exception 'version_not_draft'; end if;
  if v.rate is null and v.coefficient is null
     and not exists(
       select 1 from public.commercial_conditions c
       where c.organization_id=v.organization_id
         and c.product_table_version_id=v.id
     )
  then raise exception 'rate_or_coefficient_required'; end if;

  v_start:=coalesce(v.effective_from,now());

  perform set_config('corban.catalog_rpc','on',true);

  -- Same-start scheduled revisions are historical replacements, not concurrent prices.
  update public.product_table_versions x
  set status='superseded',
      effective_until=v_start
  where x.organization_id=v.organization_id
    and x.product_table_id=v.product_table_id
    and x.id<>v.id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)=v_start;

  -- Earlier published versions remain immutable history but stop exactly when this one starts.
  update public.product_table_versions x
  set effective_until=v_start
  where x.organization_id=v.organization_id
    and x.product_table_id=v.product_table_id
    and x.id<>v.id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<v_start
    and (x.effective_until is null or x.effective_until>v_start);

  -- Publishing out of chronological order would create an ambiguous interval.
  if exists(
    select 1
    from public.product_table_versions x
    where x.organization_id=v.organization_id
      and x.product_table_id=v.product_table_id
      and x.id<>v.id
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)>v_start
  ) then
    perform set_config('corban.catalog_rpc','off',true);
    raise exception 'future_published_version_exists';
  end if;

  update public.product_table_versions
  set status='published',
      published_at=now(),
      effective_from=v_start
  where id=v.id;

  perform set_config('corban.catalog_rpc','off',true);
  return v.id;
exception when others then
  perform set_config('corban.catalog_rpc','off',true);
  raise;
end
$$;

create or replace function public.create_simulation(
  p_customer_id uuid,
  p_table_version_id uuid,
  p_requested_amount numeric,
  p_term integer
)
returns uuid
language plpgsql
set search_path=''
as $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_amount numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);

  select c.* into v_customer
  from public.clients c
  where c.id=p_customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select v.* into v_version
  from public.product_table_versions v
  where v.id=p_table_version_id
    and v.organization_id=v_customer.organization_id
    and v.status='published'
    and coalesce(v.effective_from,v.published_at,v.created_at)<=v_now
    and (v.effective_until is null or v_now<v.effective_until);

  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;
  if v_version.term_min is not null and p_term<v_version.term_min then raise exception 'term_below_table_minimum'; end if;
  if v_version.term_max is not null and p_term>v_version.term_max then raise exception 'term_above_table_maximum'; end if;

  v_installment:=case when v_version.coefficient is not null and v_version.coefficient>0 then round(v_amount*v_version.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,
    input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,v_version.rate,v_version.coefficient,
    jsonb_build_object('requested_amount',v_amount,'term',p_term,'pricing_effective_at',v_now),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;

create or replace function public.create_simulation_for_condition(
  p_customer_id uuid,
  p_table_version_id uuid,
  p_contract_type_id uuid,
  p_requested_amount numeric,
  p_term integer
)
returns uuid
language plpgsql
set search_path=''
as $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  c public.commercial_conditions%rowtype;
  v_amount numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);

  select cl.* into v_customer
  from public.clients cl
  where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version
  from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);

  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c
  from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and k.term=p_term;
  if c.id is null then raise exception 'condition_not_found'; end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0 then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,
    input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,
      'term',p_term,
      'contract_type_id',p_contract_type_id,
      'condition_id',c.id,
      'pricing_effective_at',v_now
    ),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;

create or replace function public.create_proposal_from_simulation(p_simulation_id uuid)
returns uuid
language plpgsql
set search_path=''
as $$
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
    expected_commission_amount,customer_snapshot,commercial_snapshot,attribution_snapshot,created_by
  ) values(
    v_org,v_customer.id,v_sim.id,v_version.id,'draft',
    v_sim.requested_amount,v_sim.released_amount,v_sim.installment_amount,
    v_sim.term,v_sim.rate,v_sim.coefficient,v_sim.expected_commission_amount,
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
    auth.uid()
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
$$;

create or replace function public.apply_smart_commercial_remittance(
  p_organization uuid,
  p_production_origin text,
  p_provider uuid,
  p_policy_version uuid,
  p_rows jsonb,
  p_mode text,
  p_remittance_effective_from timestamptz default null
)
returns jsonb
language plpgsql
set search_path=''
as $$
declare
  v_import jsonb;
  rowj jsonb;
  v_bank_name text;
  v_agreement_name text;
  v_first_bank text;
  v_first_agreement text;
  v_scope_route uuid;
  v_scope_bank uuid;
  v_scope_agreement uuid;
  v_table public.product_tables%rowtype;
  v_version public.product_table_versions%rowtype;
  v_touched uuid[]:='{}';
  v_names text[]:='{}';
  v_published integer:=0;
  v_retired integer:=0;
  v_name text;
begin
  if auth.uid() is null or p_organization is null
     or not public.has_active_organization_role(p_organization,array['admin','manager'])
  then raise exception 'not_authorized'; end if;
  if p_mode not in ('partial','complete') then raise exception 'invalid_remittance_mode'; end if;
  if p_mode='complete' and p_remittance_effective_from is null then raise exception 'remittance_effective_from_required'; end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)<1 then raise exception 'invalid_smart_import_rows'; end if;

  -- Complete remittances are intentionally scoped to one Institution + Agreement.
  for rowj in select * from jsonb_array_elements(p_rows) loop
    v_bank_name:=lower(btrim(rowj->>'bank_name'));
    v_agreement_name:=lower(btrim(rowj->>'agreement_name'));
    if v_first_bank is null then
      v_first_bank:=v_bank_name;
      v_first_agreement:=v_agreement_name;
    elsif p_mode='complete' and (v_bank_name<>v_first_bank or v_agreement_name<>v_first_agreement) then
      raise exception 'complete_remittance_requires_single_scope';
    end if;
    v_name:=lower(btrim(rowj->>'table_name'));
    if not (v_name=any(v_names)) then v_names:=v_names||v_name; end if;
  end loop;

  v_import:=public.import_smart_commercial_rows(
    p_organization,p_production_origin,p_provider,p_policy_version,p_rows
  );

  -- Identify every table touched by this file and publish its resulting draft atomically.
  for v_table in
    select distinct pt.*
    from public.product_tables pt
    join public.organization_product_routes r on r.id=pt.route_id
    join public.organization_banks b on b.id=r.org_bank_id
    join public.organization_agreements a on a.id=r.org_agreement_id
    where pt.organization_id=p_organization
      and lower(btrim(pt.name))=any(v_names)
      and exists(
        select 1
        from jsonb_array_elements(p_rows) j
        where lower(btrim(j->>'table_name'))=lower(btrim(pt.name))
          and lower(btrim(j->>'bank_name'))=lower(btrim(b.name))
          and lower(btrim(j->>'agreement_name'))=lower(btrim(a.name))
      )
  loop
    select * into v_version
    from public.product_table_versions x
    where x.organization_id=p_organization
      and x.product_table_id=v_table.id
      and x.status='draft'
    order by x.version desc
    limit 1;

    if v_version.id is null then raise exception 'imported_draft_version_not_found'; end if;

    if p_mode='complete' then
      update public.product_table_versions
      set metadata=metadata||jsonb_build_object(
        'remittance_mode','complete',
        'remittance_effective_from',p_remittance_effective_from
      )
      where id=v_version.id;
    else
      update public.product_table_versions
      set metadata=metadata||jsonb_build_object('remittance_mode','partial')
      where id=v_version.id;
    end if;

    perform public.publish_product_table_version(v_version.id);
    v_touched:=v_touched||v_table.id;
    v_published:=v_published+1;
  end loop;

  if p_mode='complete' then
    select r.id,r.org_bank_id,r.org_agreement_id
    into v_scope_route,v_scope_bank,v_scope_agreement
    from public.organization_product_routes r
    join public.organization_banks b on b.id=r.org_bank_id
    join public.organization_agreements a on a.id=r.org_agreement_id
    where r.organization_id=p_organization
      and lower(btrim(b.name))=v_first_bank
      and lower(btrim(a.name))=v_first_agreement
      and ((p_provider is null and r.org_provider_id is null) or r.org_provider_id=p_provider)
      and r.production_origin=p_production_origin
    limit 1;

    if v_scope_route is null then raise exception 'complete_remittance_scope_not_found'; end if;

    perform set_config('corban.catalog_rpc','on',true);

    -- Any table absent from a complete remittance stops being available at the cutover.
    update public.product_table_versions x
    set effective_until=p_remittance_effective_from
    from public.product_tables pt
    where pt.id=x.product_table_id
      and pt.organization_id=p_organization
      and pt.route_id=v_scope_route
      and not (pt.id=any(v_touched))
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)<p_remittance_effective_from
      and (x.effective_until is null or x.effective_until>p_remittance_effective_from);
    get diagnostics v_retired=row_count;

    -- A scheduled future version of an absent table must not resurrect it after the cutover.
    update public.product_table_versions x
    set status='superseded',
        effective_until=coalesce(x.effective_until,p_remittance_effective_from)
    from public.product_tables pt
    where pt.id=x.product_table_id
      and pt.organization_id=p_organization
      and pt.route_id=v_scope_route
      and not (pt.id=any(v_touched))
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)>=p_remittance_effective_from;

    perform set_config('corban.catalog_rpc','off',true);
  end if;

  return v_import||jsonb_build_object(
    'published_versions',v_published,
    'retired_absent_versions',v_retired,
    'remittance_mode',p_mode
  );
exception when others then
  perform set_config('corban.catalog_rpc','off',true);
  raise;
end
$$;

revoke all on function public.apply_smart_commercial_remittance(uuid,text,uuid,uuid,jsonb,text,timestamptz) from public,anon;
grant execute on function public.apply_smart_commercial_remittance(uuid,text,uuid,uuid,jsonb,text,timestamptz) to authenticated;
