-- CORBAN OS V2 — Expected Commission Publisher V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Publishes expected economic facts only from a frozen proposal commercial snapshot + published rules.

create or replace function public.publish_expected_commission(p_proposal_id uuid)
returns integer language plpgsql security invoker set search_path=public as $$
declare
 v_user uuid:=auth.uid(); v_org uuid; v_snap public.proposal_commercial_snapshots%rowtype;
 v_rule public.channel_commission_rule_versions%rowtype; v_component public.commission_rule_components%rowtype;
 v_split public.network_split_rule_versions%rowtype; v_base numeric; v_gross numeric; v_tenant numeric; v_count integer:=0;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 select * into v_snap from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 if not found or v_snap.commission_rule_version_id is null then raise exception 'frozen_commercial_snapshot_required'; end if;
 select * into v_rule from public.channel_commission_rule_versions where id=v_snap.commission_rule_version_id and organization_id=v_org;
 if not found or v_rule.status<>'published' or v_rule.published_at is null then raise exception 'published_commission_rule_required'; end if;
 if v_snap.split_rule_version_id is not null then
  select * into v_split from public.network_split_rule_versions where id=v_snap.split_rule_version_id and organization_id=v_org;
  if not found or v_split.status<>'published' then raise exception 'published_split_rule_required'; end if;
 end if;
 v_base:=nullif(v_snap.snapshot->>'calculation_base_amount','')::numeric;
 if v_base is null or v_base<0 then raise exception 'snapshot_calculation_base_required'; end if;

 for v_component in select * from public.commission_rule_components where rule_version_id=v_rule.id and organization_id=v_org order by id loop
  if v_component.percentage is null and v_component.fixed_amount is null then raise exception 'component_value_required'; end if;
  v_gross:=coalesce(v_component.fixed_amount, v_base*v_component.percentage/100);
  if v_component.component_type='deferred_anticipation' then
   if v_component.anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
   v_gross:=v_gross*v_component.anticipation_factor;
  end if;
  v_tenant:=v_gross;
  if v_snap.split_rule_version_id is not null and (v_split.component_type is null or v_split.component_type=v_component.component_type) then v_tenant:=v_gross*v_split.upstream_share; end if;

  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_snap.channel_id,v_snap.producer_entity_id,v_snap.payer_entity_id,'commission_expected',v_component.component_type,v_tenant,'BRL',now(),
   'expected:'||p_proposal_id::text||':'||v_rule.id::text||':'||v_component.id::text||':'||coalesce(v_snap.split_rule_version_id::text,'none'),
   'proposal_snapshot',p_proposal_id::text,jsonb_build_object('gross_amount',v_gross,'tenant_amount',v_tenant,'calculation_base',v_base,'commission_rule_version_id',v_rule.id,'split_rule_version_id',v_snap.split_rule_version_id),v_user)
  on conflict(organization_id,idempotency_key) do nothing;
  if found then v_count:=v_count+1; end if;
 end loop;
 if v_count=0 and not exists(select 1 from public.financial_events where organization_id=v_org and proposal_id=p_proposal_id and source_kind='proposal_snapshot') then raise exception 'no_commission_components'; end if;
 return v_count;
end $$;
revoke all on function public.publish_expected_commission(uuid) from public,anon;
grant execute on function public.publish_expected_commission(uuid) to authenticated;
