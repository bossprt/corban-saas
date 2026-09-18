-- CORBAN OS V2 — Per-component commercial snapshot V0
create table if not exists public.proposal_commercial_component_snapshots(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 proposal_id uuid not null references public.proposals_v2(id),
 component_type text not null,
 commission_component_id uuid not null references public.commission_rule_components(id),
 split_rule_version_id uuid references public.network_split_rule_versions(id),
 gross_percentage numeric,
 fixed_amount numeric,
 anticipation_factor numeric,
 upstream_share numeric not null default 1 check(upstream_share>=0 and upstream_share<=1),
 downstream_share numeric not null default 0 check(downstream_share>=0 and downstream_share<=1),
 snapshot jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(organization_id,proposal_id,commission_component_id),
 check(upstream_share+downstream_share=1)
);
alter table public.proposal_commercial_component_snapshots enable row level security;
revoke all on public.proposal_commercial_component_snapshots from anon;
create policy proposal_commercial_component_snapshots_select on public.proposal_commercial_component_snapshots for select to authenticated using(public.is_active_organization_member(organization_id));
-- snapshots only through guarded RPC; no direct authenticated insert/update/delete.
grant select on public.proposal_commercial_component_snapshots to authenticated;

create or replace function public.freeze_proposal_commercial_route(p_proposal_id uuid,p_channel_id uuid,p_commission_rule_version_id uuid,p_producer_entity_id uuid default null)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_org uuid;v_table uuid;v_amount numeric;v_channel public.commercial_channels%rowtype;v_rule public.channel_commission_rule_versions%rowtype;v_comp public.commission_rule_components%rowtype;v_split public.network_split_rule_versions%rowtype;
begin
 select p.organization_id,v.product_table_id,coalesce(p.released_amount,p.requested_amount) into v_org,v_table,v_amount
 from public.proposals_v2 p join public.product_table_versions v on v.id=p.product_table_version_id and v.organization_id=p.organization_id
 where p.id=p_proposal_id and p.status='draft' and public.is_active_organization_member(p.organization_id);
 if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if v_amount is null or v_amount<0 then raise exception 'proposal_calculation_base_required'; end if;
 select * into v_channel from public.commercial_channels where id=p_channel_id and organization_id=v_org and is_active;
 if not found then raise exception 'active_channel_required'; end if;
 select * into v_rule from public.channel_commission_rule_versions where id=p_commission_rule_version_id and organization_id=v_org and channel_id=p_channel_id and product_table_id=v_table and status='published';
 if not found then raise exception 'published_rule_for_channel_table_required'; end if;
 if p_producer_entity_id is not null and not exists(select 1 from public.commercial_entities where id=p_producer_entity_id and organization_id=v_org and is_active) then raise exception 'producer_not_found'; end if;
 if exists(select 1 from public.proposal_commercial_snapshots where proposal_id=p_proposal_id) then raise exception 'commercial_route_already_frozen'; end if;

 insert into public.proposal_commercial_snapshots(proposal_id,organization_id,channel_id,commission_rule_version_id,producer_entity_id,payer_entity_id,split_rule_version_id,snapshot)
 values(p_proposal_id,v_org,p_channel_id,p_commission_rule_version_id,p_producer_entity_id,v_channel.payer_entity_id,null,
 jsonb_build_object('calculation_base_amount',v_amount,'product_table_id',v_table,'per_component_split',true));

 for v_comp in select * from public.commission_rule_components where organization_id=v_org and rule_version_id=v_rule.id loop
  v_split:=null;
  if v_channel.relationship_id is not null then
   select * into v_split from public.network_split_rule_versions s where s.organization_id=v_org and s.relationship_id=v_channel.relationship_id and s.status='published'
    and (s.bank_id is null or s.bank_id=v_channel.bank_id) and (s.product_table_id is null or s.product_table_id=v_table)
    and (s.component_type is null or s.component_type=v_comp.component_type)
    and s.effective_from<=now() and (s.effective_until is null or s.effective_until>now())
    order by (s.component_type=v_comp.component_type) desc,(s.product_table_id=v_table) desc,(s.bank_id=v_channel.bank_id) desc,s.version desc limit 1;
  end if;
  insert into public.proposal_commercial_component_snapshots(organization_id,proposal_id,component_type,commission_component_id,split_rule_version_id,gross_percentage,fixed_amount,anticipation_factor,upstream_share,downstream_share,snapshot)
  values(v_org,p_proposal_id,v_comp.component_type,v_comp.id,v_split.id,v_comp.percentage,v_comp.fixed_amount,v_comp.anticipation_factor,coalesce(v_split.upstream_share,1),coalesce(v_split.downstream_share,0),
   jsonb_build_object('calculation_base',v_comp.calculation_base,'commission_rule_version_id',v_rule.id,'split_rule_version_id',v_split.id));
 end loop;
 return p_proposal_id;
end $$;
revoke all on function public.freeze_proposal_commercial_route(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.freeze_proposal_commercial_route(uuid,uuid,uuid,uuid) to authenticated;

create or replace function public.publish_expected_commission(p_proposal_id uuid)
returns integer language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_snap public.proposal_commercial_snapshots%rowtype;v_cs public.proposal_commercial_component_snapshots%rowtype;v_base numeric;v_gross numeric;v_tenant numeric;v_count integer:=0;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 select * into v_snap from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 if not found or v_snap.commission_rule_version_id is null then raise exception 'frozen_commercial_snapshot_required'; end if;
 v_base:=nullif(v_snap.snapshot->>'calculation_base_amount','')::numeric;
 if v_base is null or v_base<0 then raise exception 'snapshot_calculation_base_required'; end if;
 if not exists(select 1 from public.proposal_commercial_component_snapshots where proposal_id=p_proposal_id and organization_id=v_org) then raise exception 'per_component_snapshot_required'; end if;
 for v_cs in select * from public.proposal_commercial_component_snapshots where proposal_id=p_proposal_id and organization_id=v_org order by id loop
  if v_cs.gross_percentage is null and v_cs.fixed_amount is null then raise exception 'component_value_required'; end if;
  v_gross:=coalesce(v_cs.fixed_amount,v_base*v_cs.gross_percentage/100);
  if v_cs.component_type='deferred_anticipation' then if v_cs.anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;v_gross:=v_gross*v_cs.anticipation_factor;end if;
  v_tenant:=v_gross*v_cs.upstream_share;
  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_snap.channel_id,v_snap.producer_entity_id,v_snap.payer_entity_id,'commission_expected',v_cs.component_type,v_tenant,'BRL',now(),
  'expected:'||p_proposal_id::text||':'||v_cs.commission_component_id::text||':'||coalesce(v_cs.split_rule_version_id::text,'none'),
  'proposal_snapshot',p_proposal_id::text,jsonb_build_object('gross_amount',v_gross,'tenant_amount',v_tenant,'calculation_base',v_base,'upstream_share',v_cs.upstream_share,'downstream_share',v_cs.downstream_share,'split_rule_version_id',v_cs.split_rule_version_id),v_user)
  on conflict(organization_id,idempotency_key) do nothing;
  if found then v_count:=v_count+1;end if;
 end loop;
 return v_count;
end $$;
