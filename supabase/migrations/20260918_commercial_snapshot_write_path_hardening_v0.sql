-- CORBAN OS V2 — Commercial snapshot write-path hardening.
create or replace function public.guard_proposal_commercial_route_insert() returns trigger language plpgsql set search_path=public as $$
begin
 if current_setting('corban.commercial_route_rpc',true) is distinct from 'on' then raise exception 'commercial_snapshot_requires_freeze_rpc'; end if;
 return new;
end $$;
drop trigger if exists proposal_commercial_route_insert_guard on public.proposal_commercial_snapshots;
create trigger proposal_commercial_route_insert_guard before insert on public.proposal_commercial_snapshots for each row execute function public.guard_proposal_commercial_route_insert();
drop trigger if exists proposal_component_route_insert_guard on public.proposal_commercial_component_snapshots;
create trigger proposal_component_route_insert_guard before insert on public.proposal_commercial_component_snapshots for each row execute function public.guard_proposal_commercial_route_insert();
revoke all on function public.guard_proposal_commercial_route_insert() from public,anon,authenticated;
grant insert on public.proposal_commercial_component_snapshots to authenticated;
create policy proposal_component_snapshot_insert_guarded on public.proposal_commercial_component_snapshots for insert to authenticated
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

create or replace function public.freeze_proposal_commercial_route(p_proposal_id uuid,p_channel_id uuid,p_commission_rule_version_id uuid,p_producer_entity_id uuid default null)
returns uuid language plpgsql security invoker set search_path=public as $$
declare v_org uuid;v_table uuid;v_amount numeric;v_channel public.commercial_channels%rowtype;v_rule public.channel_commission_rule_versions%rowtype;v_comp public.commission_rule_components%rowtype;v_split public.network_split_rule_versions%rowtype;
begin
 select p.organization_id,v.product_table_id,coalesce(p.released_amount,p.requested_amount) into v_org,v_table,v_amount from public.proposals_v2 p join public.product_table_versions v on v.id=p.product_table_version_id and v.organization_id=p.organization_id where p.id=p_proposal_id and p.status='draft' and public.is_active_organization_member(p.organization_id);
 if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if v_amount is null or v_amount<0 then raise exception 'proposal_calculation_base_required'; end if;
 select * into v_channel from public.commercial_channels where id=p_channel_id and organization_id=v_org and is_active;
 if not found then raise exception 'active_channel_required'; end if;
 select * into v_rule from public.channel_commission_rule_versions where id=p_commission_rule_version_id and organization_id=v_org and channel_id=p_channel_id and product_table_id=v_table and status='published';
 if not found then raise exception 'published_rule_for_channel_table_required'; end if;
 if p_producer_entity_id is not null and not exists(select 1 from public.commercial_entities where id=p_producer_entity_id and organization_id=v_org and is_active) then raise exception 'producer_not_found'; end if;
 if exists(select 1 from public.proposal_commercial_snapshots where proposal_id=p_proposal_id) then raise exception 'commercial_route_already_frozen'; end if;
 perform set_config('corban.commercial_route_rpc','on',true);
 insert into public.proposal_commercial_snapshots(proposal_id,organization_id,channel_id,commission_rule_version_id,producer_entity_id,payer_entity_id,split_rule_version_id,snapshot)
 values(p_proposal_id,v_org,p_channel_id,p_commission_rule_version_id,p_producer_entity_id,v_channel.payer_entity_id,null,jsonb_build_object('calculation_base_amount',v_amount,'product_table_id',v_table,'per_component_split',true));
 for v_comp in select * from public.commission_rule_components where organization_id=v_org and rule_version_id=v_rule.id loop
  v_split:=null;
  if v_channel.relationship_id is not null then
   select * into v_split from public.network_split_rule_versions s where s.organization_id=v_org and s.relationship_id=v_channel.relationship_id and s.status='published' and (s.bank_id is null or s.bank_id=v_channel.bank_id) and (s.product_table_id is null or s.product_table_id=v_table) and (s.component_type is null or s.component_type=v_comp.component_type) and s.effective_from<=now() and (s.effective_until is null or s.effective_until>now()) order by (s.component_type=v_comp.component_type) desc,(s.product_table_id=v_table) desc,(s.bank_id=v_channel.bank_id) desc,s.version desc limit 1;
  end if;
  insert into public.proposal_commercial_component_snapshots(organization_id,proposal_id,component_type,commission_component_id,split_rule_version_id,gross_percentage,fixed_amount,anticipation_factor,upstream_share,downstream_share,snapshot)
  values(v_org,p_proposal_id,v_comp.component_type,v_comp.id,v_split.id,v_comp.percentage,v_comp.fixed_amount,v_comp.anticipation_factor,coalesce(v_split.upstream_share,1),coalesce(v_split.downstream_share,0),jsonb_build_object('calculation_base',v_comp.calculation_base,'commission_rule_version_id',v_rule.id,'split_rule_version_id',v_split.id));
 end loop;
 perform set_config('corban.commercial_route_rpc','off',true);
 return p_proposal_id;
end $$;