-- CORBAN OS — Proposal/financial integrity hardening V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Goals:
-- 1) enforce commission-rule effective window in the governed freeze RPC;
-- 2) keep reconciliation cases synchronized when expected/evidence facts are published directly;
-- 3) remove unnecessary UPDATE/DELETE table privileges from immutable commercial snapshots.

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
   and status='published'
   and (effective_from is null or effective_from<=now())
   and (effective_until is null or effective_until>now());
 if not found then raise exception 'published_effective_rule_for_channel_table_required'; end if;

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

  perform public.refresh_financial_reconciliation(p_proposal_id,v_cs.component_type);
 end loop;

 return v_count;
end
$$;

revoke all on function public.publish_expected_commission(uuid) from public,anon;
grant execute on function public.publish_expected_commission(uuid) to authenticated;

create or replace function public.publish_financial_evidence_event(
 p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric,
 p_occurred_at timestamptz, p_source_kind text, p_source_reference text,
 p_import_batch_id uuid default null, p_import_raw_row_id uuid default null, p_import_decision_id uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path=public
as $$
declare
 v_user uuid:=auth.uid();
 v_org uuid;
 v_event uuid;
 v_channel uuid;
 v_producer uuid;
 v_payer uuid;
 v_key text;
 v_semantic text;
 v_raw_batch uuid;
 v_decision_batch uuid;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence') then raise exception 'confirmed_evidence_source_required'; end if;

 select channel_id,producer_entity_id,payer_entity_id
 into v_channel,v_producer,v_payer
 from public.proposal_commercial_snapshots
 where proposal_id=p_proposal_id and organization_id=v_org;
 if not found then raise exception 'frozen_commercial_snapshot_required'; end if;

 if p_source_kind='import' then
  if p_import_batch_id is null then raise exception 'import_batch_required'; end if;
  select s.financial_semantic into v_semantic
  from public.import_batches b
  join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id
  where b.id=p_import_batch_id and b.organization_id=v_org;
  if v_semantic is null then raise exception 'batch_not_found'; end if;
  if p_event_type='commission_reported' and v_semantic<>'commission_statement' then raise exception 'source_does_not_prove_reported_commission'; end if;
  if p_event_type='payment_received' and v_semantic<>'payment_statement' then raise exception 'source_does_not_prove_payment'; end if;
  if p_event_type='downstream_paid' and v_semantic<>'network_payment_statement' then raise exception 'source_does_not_prove_network_payment'; end if;
  if p_import_raw_row_id is not null then
   select batch_id into v_raw_batch from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org;
   if v_raw_batch is distinct from p_import_batch_id then raise exception 'raw_row_batch_mismatch'; end if;
  end if;
  if p_import_decision_id is not null then
   select batch_id into v_decision_batch from public.import_decisions where id=p_import_decision_id and organization_id=v_org;
   if v_decision_batch is distinct from p_import_batch_id then raise exception 'decision_batch_mismatch'; end if;
  end if;
 elsif nullif(trim(p_source_reference),'') is null then
  raise exception 'external_evidence_reference_required';
 end if;

 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||
   encode(extensions.digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');

 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is null then
  perform set_config('corban.financial_evidence_rpc','on',true);
  insert into public.financial_events(
    organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,
    event_type,component_type,amount,currency,occurred_at,idempotency_key,
    source_kind,source_reference,metadata,created_by
  )
  values(
    v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,
    'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,
    jsonb_build_object('evidence_semantic',v_semantic),v_user
  )
  returning id into v_event;
  perform set_config('corban.financial_evidence_rpc','off',true);
 end if;

 insert into public.financial_evidence_links(
   organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,
   evidence_kind,evidence_reference
 )
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference
 where not exists(
   select 1 from public.financial_evidence_links
   where financial_event_id=v_event
     and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(evidence_reference,'')=coalesce(p_source_reference,'')
 );

 if p_event_type in ('commission_reported','payment_received') then
  perform public.refresh_financial_reconciliation(p_proposal_id,p_component_type);
 end if;

 return v_event;
end
$$;

revoke all on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) to authenticated;

revoke update,delete on table public.proposal_commercial_snapshots from authenticated,anon;
revoke update,delete on table public.proposal_commercial_component_snapshots from authenticated,anon;
