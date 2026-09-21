-- CORBAN OS — Seller/SUB proposal snapshot V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Goal: freeze seller attribution and SUB economics into proposal component snapshots.
-- Existing proposals remain economically unchanged: seller company share defaults to 100%.

alter table public.proposals_v2
  add column seller_id uuid;

alter table public.proposals_v2
  add constraint proposals_v2_seller_tenant_fk
  foreign key (organization_id,seller_id)
  references public.commercial_sellers(organization_id,id)
  on delete restrict;

create index proposals_v2_org_seller_idx
  on public.proposals_v2(organization_id,seller_id)
  where seller_id is not null;

create unique index seller_sub_rule_org_seller_id_key
  on public.seller_sub_rule_versions(organization_id,seller_id,id);

alter table public.proposal_commercial_component_snapshots
  add column seller_id uuid,
  add column seller_sub_rule_version_id uuid,
  add column seller_sub_share_pct numeric(9,6) not null default 0,
  add column seller_company_share_pct numeric(9,6) not null default 100;

alter table public.proposal_commercial_component_snapshots
  add constraint proposal_component_snapshot_seller_tenant_fk
    foreign key (organization_id,seller_id)
    references public.commercial_sellers(organization_id,id)
    on delete restrict,
  add constraint proposal_component_snapshot_sub_rule_fk
    foreign key (organization_id,seller_id,seller_sub_rule_version_id)
    references public.seller_sub_rule_versions(organization_id,seller_id,id)
    on delete restrict,
  add constraint proposal_component_snapshot_seller_share_range_check
    check (
      seller_sub_share_pct between 0 and 100
      and seller_company_share_pct between 0 and 100
      and seller_sub_share_pct + seller_company_share_pct = 100
    ),
  add constraint proposal_component_snapshot_sub_rule_semantics_check
    check (
      seller_sub_rule_version_id is not null
      or (seller_sub_share_pct=0 and seller_company_share_pct=100)
    );

create index proposal_component_snapshot_seller_idx
  on public.proposal_commercial_component_snapshots(organization_id,seller_id)
  where seller_id is not null;

create index proposal_component_snapshot_sub_rule_idx
  on public.proposal_commercial_component_snapshots(organization_id,seller_sub_rule_version_id)
  where seller_sub_rule_version_id is not null;

-- Seller attribution can only change through a dedicated governed RPC, while proposal is still draft
-- and before the commercial route has been frozen.
create or replace function public.guard_proposal_write()
returns trigger
language plpgsql
set search_path=''
as $$
begin
 if current_user in ('authenticated','anon','service_role')
    and current_setting('corban.proposal_rpc',true) is distinct from 'on'
    and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on'
    and current_setting('corban.proposal_seller_rpc',true) is distinct from 'on' then
  raise exception 'proposal_write_requires_governed_rpc';
 end if;

 if tg_op='UPDATE' and new.seller_id is distinct from old.seller_id then
  if current_setting('corban.proposal_seller_rpc',true) is distinct from 'on' then
    raise exception 'proposal_seller_change_requires_governed_rpc';
  end if;
  if old.status<>'draft' or exists(
    select 1 from public.proposal_commercial_snapshots s
    where s.proposal_id=old.id and s.organization_id=old.organization_id
  ) then
    raise exception 'proposal_seller_is_frozen';
  end if;
 end if;

 if tg_op='UPDATE' and (
    new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.customer_id is distinct from old.customer_id
    or new.simulation_id is distinct from old.simulation_id
    or new.product_table_version_id is distinct from old.product_table_version_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
 ) then
  raise exception 'proposal_identity_is_immutable';
 end if;
 return new;
end
$$;

revoke all on function public.guard_proposal_write() from public,anon,authenticated;

create or replace function public.guard_proposal_commercial_snapshot()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_op='INSERT'
     or (tg_op='UPDATE' and old.status='draft'
         and new.product_table_version_id is distinct from old.product_table_version_id) then
    if not exists(
      select 1 from public.product_table_versions v
      where v.organization_id=new.organization_id
        and v.id=new.product_table_version_id
        and v.status='published'
    ) then
      raise exception 'proposal_requires_published_product_table_version';
    end if;
  end if;

  if tg_op='UPDATE' and old.status<>'draft' then
    if new.status='draft' then raise exception 'proposal_cannot_return_to_draft'; end if;
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.simulation_id is distinct from old.simulation_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.seller_id is distinct from old.seller_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.expected_commission_amount is distinct from old.expected_commission_amount
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.commercial_snapshot is distinct from old.commercial_snapshot
       or new.attribution_snapshot is distinct from old.attribution_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'proposal_commercial_snapshot_is_immutable_after_draft';
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.guard_proposal_commercial_snapshot() from public,anon,authenticated;

create or replace function public.assign_proposal_seller(p_proposal_id uuid,p_seller_id uuid)
returns uuid
language plpgsql
set search_path=''
as $$
declare
  v_org uuid;
  v_seller public.commercial_sellers%rowtype;
  v_attr jsonb;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select p.organization_id,p.attribution_snapshot
    into v_org,v_attr
  from public.proposals_v2 p
  where p.id=p_proposal_id
    and p.status='draft'
    and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then
    raise exception 'forbidden';
  end if;
  if exists(
    select 1 from public.proposal_commercial_snapshots s
    where s.proposal_id=p_proposal_id and s.organization_id=v_org
  ) then
    raise exception 'proposal_commercial_route_already_frozen';
  end if;

  if p_seller_id is not null then
    select * into v_seller
    from public.commercial_sellers s
    where s.id=p_seller_id and s.organization_id=v_org and s.is_active;
    if not found then raise exception 'active_seller_not_found'; end if;

    v_attr:=coalesce(v_attr,'{}'::jsonb) ||
      jsonb_build_object('seller',jsonb_build_object(
        'id',v_seller.id,
        'name',v_seller.name,
        'category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'assigned_at',now()
      ));
  else
    v_attr:=coalesce(v_attr,'{}'::jsonb)-'seller';
  end if;

  perform set_config('corban.proposal_seller_rpc','on',true);
  update public.proposals_v2
     set seller_id=p_seller_id,
         attribution_snapshot=v_attr,
         updated_at=now()
   where id=p_proposal_id and organization_id=v_org;
  perform set_config('corban.proposal_seller_rpc','off',true);

  return p_proposal_id;
end
$$;

revoke all on function public.assign_proposal_seller(uuid,uuid) from public,anon;
grant execute on function public.assign_proposal_seller(uuid,uuid) to authenticated;

-- Freeze seller identity and the effective SUB rule independently for every commission component.
create or replace function public.freeze_proposal_commercial_route(
  p_proposal_id uuid,
  p_channel_id uuid,
  p_commission_rule_version_id uuid,
  p_producer_entity_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path=public
as $$
declare
  v_org uuid;
  v_table uuid;
  v_amount numeric;
  v_seller_id uuid;
  v_channel public.commercial_channels%rowtype;
  v_rule public.channel_commission_rule_versions%rowtype;
  v_comp public.commission_rule_components%rowtype;
  v_split public.network_split_rule_versions%rowtype;
  v_seller public.commercial_sellers%rowtype;
  v_sub public.seller_sub_rule_versions%rowtype;
  v_sub_share numeric:=0;
  v_company_share numeric:=100;
begin
 select p.organization_id,v.product_table_id,coalesce(p.released_amount,p.requested_amount),p.seller_id
   into v_org,v_table,v_amount,v_seller_id
 from public.proposals_v2 p
 join public.product_table_versions v
   on v.id=p.product_table_version_id and v.organization_id=p.organization_id
 where p.id=p_proposal_id
   and p.status='draft'
   and public.is_active_organization_member(p.organization_id);

 if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if v_amount is null or v_amount<0 then raise exception 'proposal_calculation_base_required'; end if;

 if v_seller_id is not null then
  select * into v_seller
  from public.commercial_sellers s
  where s.id=v_seller_id and s.organization_id=v_org and s.is_active;
  if not found then raise exception 'active_seller_required'; end if;
 end if;

 select * into v_channel
 from public.commercial_channels
 where id=p_channel_id and organization_id=v_org and is_active;
 if not found then raise exception 'active_channel_required'; end if;

 select * into v_rule
 from public.channel_commission_rule_versions
 where id=p_commission_rule_version_id
   and organization_id=v_org
   and channel_id=p_channel_id
   and product_table_id=v_table
   and status='published';
 if not found then raise exception 'published_rule_for_channel_table_required'; end if;

 if p_producer_entity_id is not null
    and not exists(
      select 1 from public.commercial_entities
      where id=p_producer_entity_id and organization_id=v_org and is_active
    ) then
  raise exception 'producer_not_found';
 end if;

 if exists(select 1 from public.proposal_commercial_snapshots where proposal_id=p_proposal_id) then
  raise exception 'commercial_route_already_frozen';
 end if;

 perform set_config('corban.commercial_route_rpc','on',true);

 insert into public.proposal_commercial_snapshots(
   proposal_id,organization_id,channel_id,commission_rule_version_id,
   producer_entity_id,payer_entity_id,split_rule_version_id,snapshot
 )
 values(
   p_proposal_id,v_org,p_channel_id,p_commission_rule_version_id,
   p_producer_entity_id,v_channel.payer_entity_id,null,
   jsonb_build_object(
     'calculation_base_amount',v_amount,
     'product_table_id',v_table,
     'per_component_split',true,
     'seller_id',v_seller_id,
     'seller_category',case when v_seller_id is null then null else v_seller.seller_category end,
     'seller_group_id',case when v_seller_id is null then null else v_seller.seller_group_id end
   )
 );

 for v_comp in
   select * from public.commission_rule_components
   where organization_id=v_org and rule_version_id=v_rule.id
 loop
  v_split:=null;
  if v_channel.relationship_id is not null then
   select * into v_split
   from public.network_split_rule_versions s
   where s.organization_id=v_org
     and s.relationship_id=v_channel.relationship_id
     and s.status='published'
     and (s.bank_id is null or s.bank_id=v_channel.bank_id)
     and (s.product_table_id is null or s.product_table_id=v_table)
     and (s.component_type is null or s.component_type=v_comp.component_type)
     and s.effective_from<=now()
     and (s.effective_until is null or s.effective_until>now())
   order by
     (s.component_type=v_comp.component_type) desc,
     (s.product_table_id=v_table) desc,
     (s.bank_id=v_channel.bank_id) desc,
     s.version desc
   limit 1;
  end if;

  v_sub:=null;
  v_sub_share:=0;
  v_company_share:=100;

  if v_seller_id is not null and v_seller.seller_category='sub' then
   select * into v_sub
   from public.seller_sub_rule_versions sr
   where sr.organization_id=v_org
     and sr.seller_id=v_seller_id
     and sr.status='published'
     and sr.effective_from<=now()
     and sr.component_key in (v_comp.component_type,'all')
   order by
     (sr.component_key=v_comp.component_type) desc,
     sr.effective_from desc,
     sr.version desc
   limit 1;

   if not found then
    raise exception 'published_sub_rule_required_for_component:%',v_comp.component_type;
   end if;
   v_sub_share:=v_sub.sub_share_pct;
   v_company_share:=v_sub.company_share_pct;
  end if;

  insert into public.proposal_commercial_component_snapshots(
    organization_id,proposal_id,component_type,commission_component_id,
    split_rule_version_id,gross_percentage,fixed_amount,anticipation_factor,
    upstream_share,downstream_share,
    seller_id,seller_sub_rule_version_id,seller_sub_share_pct,seller_company_share_pct,
    snapshot
  )
  values(
    v_org,p_proposal_id,v_comp.component_type,v_comp.id,
    v_split.id,v_comp.percentage,v_comp.fixed_amount,v_comp.anticipation_factor,
    coalesce(v_split.upstream_share,1),coalesce(v_split.downstream_share,0),
    v_seller_id,v_sub.id,v_sub_share,v_company_share,
    jsonb_build_object(
      'calculation_base',v_comp.calculation_base,
      'commission_rule_version_id',v_rule.id,
      'split_rule_version_id',v_split.id,
      'seller_id',v_seller_id,
      'seller_category',case when v_seller_id is null then null else v_seller.seller_category end,
      'seller_group_id',case when v_seller_id is null then null else v_seller.seller_group_id end,
      'commission_group_id',case when v_seller_id is null then null else v_seller.commission_group_id end,
      'seller_sub_rule_version_id',v_sub.id,
      'seller_sub_share_pct',v_sub_share,
      'seller_company_share_pct',v_company_share
    )
  );
 end loop;

 perform set_config('corban.commercial_route_rpc','off',true);
 return p_proposal_id;
end
$$;

revoke all on function public.freeze_proposal_commercial_route(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.freeze_proposal_commercial_route(uuid,uuid,uuid,uuid) to authenticated;

-- Expected company revenue = gross component × upstream/network share × frozen company share of seller/SUB.
-- Existing snapshots have seller_company_share_pct=100, so historical behavior is unchanged.
create or replace function public.publish_expected_commission(p_proposal_id uuid)
returns integer
language plpgsql
security invoker
set search_path=public
as $$
declare
 v_user uuid:=auth.uid();
 v_org uuid;
 v_snap record;
 v_cs public.proposal_commercial_component_snapshots%rowtype;
 v_base numeric;
 v_gross numeric;
 v_tenant_before_seller numeric;
 v_company numeric;
 v_count integer:=0;
 v_rows integer;
begin
 select organization_id into v_org
 from public.proposals_v2
 where id=p_proposal_id;

 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then
  raise exception 'forbidden';
 end if;

 select r.* into v_snap from private.commercial_route(p_proposal_id) r;
 if not found or v_snap.commission_rule_version_id is null then
  raise exception 'frozen_commercial_snapshot_required';
 end if;

 v_base:=nullif(v_snap.snapshot->>'calculation_base_amount','')::numeric;
 if v_base is null or v_base<0 then raise exception 'snapshot_calculation_base_required'; end if;

 if not exists(
   select 1 from public.proposal_commercial_component_snapshots
   where proposal_id=p_proposal_id and organization_id=v_org
 ) then
  raise exception 'per_component_snapshot_required';
 end if;

 for v_cs in
   select * from public.proposal_commercial_component_snapshots
   where proposal_id=p_proposal_id and organization_id=v_org
   order by id
 loop
  if v_cs.gross_percentage is null and v_cs.fixed_amount is null then
   raise exception 'component_value_required';
  end if;

  v_gross:=coalesce(v_cs.fixed_amount,v_base*v_cs.gross_percentage/100);

  if v_cs.component_type='deferred_anticipation' then
   if v_cs.anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
   v_gross:=v_gross*v_cs.anticipation_factor;
  end if;

  v_tenant_before_seller:=v_gross*v_cs.upstream_share;
  v_company:=v_tenant_before_seller*v_cs.seller_company_share_pct/100;

  perform set_config('corban.financial_expected_rpc','on',true);
  insert into public.financial_events(
    organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,
    event_type,component_type,amount,currency,occurred_at,idempotency_key,
    source_kind,source_reference,metadata,created_by
  )
  values(
    v_org,p_proposal_id,v_snap.channel_id,v_snap.producer_entity_id,v_snap.payer_entity_id,
    'commission_expected',v_cs.component_type,v_company,'BRL',now(),
    'expected:'||p_proposal_id::text||':'||v_cs.commission_component_id::text||':'||coalesce(v_cs.split_rule_version_id::text,'none'),
    'proposal_snapshot',p_proposal_id::text,
    jsonb_build_object(
      'gross_amount',v_gross,
      'tenant_before_seller_amount',v_tenant_before_seller,
      'tenant_amount',v_company,
      'company_expected_amount',v_company,
      'calculation_base',v_base,
      'upstream_share',v_cs.upstream_share,
      'downstream_share',v_cs.downstream_share,
      'split_rule_version_id',v_cs.split_rule_version_id,
      'seller_id',v_cs.seller_id,
      'seller_sub_rule_version_id',v_cs.seller_sub_rule_version_id,
      'seller_sub_share_pct',v_cs.seller_sub_share_pct,
      'seller_company_share_pct',v_cs.seller_company_share_pct
    ),
    v_user
  )
  on conflict(organization_id,idempotency_key) do nothing;

  get diagnostics v_rows=row_count;
  perform set_config('corban.financial_expected_rpc','off',true);
  v_count:=v_count+v_rows;
 end loop;

 return v_count;
end
$$;

revoke all on function public.publish_expected_commission(uuid) from public,anon;
grant execute on function public.publish_expected_commission(uuid) to authenticated;
