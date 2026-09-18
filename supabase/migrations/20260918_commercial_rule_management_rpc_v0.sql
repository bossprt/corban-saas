-- CORBAN OS V2 — Commercial Rule Management RPC V0
create or replace function public.create_and_publish_commission_rule(
 p_channel_id uuid,p_product_table_id uuid,p_component_type text,p_percentage numeric,p_fixed_amount numeric,p_anticipation_factor numeric,
 p_calculation_base text,p_effective_from timestamptz,p_operation_type text default null
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_id uuid;v_version int;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;
 if not exists(select 1 from public.commercial_channels where id=p_channel_id and organization_id=v_org) then raise exception 'channel_not_found'; end if;
 if not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 if p_percentage is null and p_fixed_amount is null then raise exception 'component_value_required'; end if;
 if p_component_type='deferred_anticipation' and p_anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
 select coalesce(max(version),0)+1 into v_version from public.channel_commission_rule_versions where organization_id=v_org and channel_id=p_channel_id and product_table_id=p_product_table_id;
 insert into public.channel_commission_rule_versions(organization_id,channel_id,product_table_id,version,status,operation_type,effective_from,published_at)
 values(v_org,p_channel_id,p_product_table_id,v_version,'published',p_operation_type,p_effective_from,now()) returning id into v_id;
 insert into public.commission_rule_components(organization_id,rule_version_id,component_type,percentage,fixed_amount,anticipation_factor,calculation_base)
 values(v_org,v_id,p_component_type,p_percentage,p_fixed_amount,p_anticipation_factor,p_calculation_base);
 return v_id;
end $$;
revoke all on function public.create_and_publish_commission_rule(uuid,uuid,text,numeric,numeric,numeric,text,timestamptz,text) from public,anon;
grant execute on function public.create_and_publish_commission_rule(uuid,uuid,text,numeric,numeric,numeric,text,timestamptz,text) to authenticated;

create or replace function public.create_and_publish_split_rule(
 p_relationship_id uuid,p_bank_id uuid,p_product_table_id uuid,p_component_type text,p_downstream_share numeric,p_payment_flow text,p_effective_from timestamptz
) returns uuid language plpgsql security invoker set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_id uuid;v_version int;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;
 if p_downstream_share<0 or p_downstream_share>1 then raise exception 'invalid_share'; end if;
 if not exists(select 1 from public.commercial_relationships where id=p_relationship_id and organization_id=v_org) then raise exception 'relationship_not_found'; end if;
 if p_product_table_id is not null and not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 select coalesce(max(version),0)+1 into v_version from public.network_split_rule_versions where organization_id=v_org and relationship_id=p_relationship_id and product_table_id is not distinct from p_product_table_id and component_type is not distinct from p_component_type;
 insert into public.network_split_rule_versions(organization_id,relationship_id,bank_id,product_table_id,component_type,version,downstream_share,upstream_share,payment_flow,effective_from,status)
 values(v_org,p_relationship_id,p_bank_id,p_product_table_id,p_component_type,v_version,p_downstream_share,1-p_downstream_share,p_payment_flow,p_effective_from,'published') returning id into v_id;
 return v_id;
end $$;
revoke all on function public.create_and_publish_split_rule(uuid,uuid,uuid,text,numeric,text,timestamptz) from public,anon;
grant execute on function public.create_and_publish_split_rule(uuid,uuid,uuid,text,numeric,text,timestamptz) to authenticated;
